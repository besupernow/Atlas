// Atlas: GStreamer video backend for adaptive streaming on Linux. See gst_av_plugin.h.
//
// Everything here runs on the GTK main thread: method calls arrive there, the bus is watched from
// the default main context, and the position timer is a GLib timeout. The one exception is
// `source-setup`, which GStreamer may emit from a streaming thread; it only reads `headers_`, which
// is written before the pipeline starts.

#include "gst_av_plugin.h"

#include <fcntl.h>
#include <gdk/gdkwayland.h>
#include <gst/gst.h>
#include <gst/video/videooverlay.h>
#include <sys/mman.h>
#include <unistd.h>
#include <wayland-client.h>

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <map>
#include <memory>
#include <string>
#include <vector>

namespace {

constexpr const char* kChannel = "com.atlas/gst_player";
constexpr const char* kLogPrefix = "gstreamer";
// playbin3's GstPlayFlags "text": subtitles are drawn by the app (AtlasSubtitleOverlay).
constexpr guint kPlayFlagText = 1u << 2;

void Log(const char* level, const std::string& text);

// ---------------------------------------------------------------------------------------------
// Wayland anchor
//
// A wl_subsurface placed *below* the Flutter toplevel, holding a 1x1 fully transparent buffer.
// waylandsink is handed this surface as its window and nests its own (video) subsurfaces inside
// it. Subsurfaces aren't clipped by their parent and inherit its place in the stack, so the video
// lands under the Flutter UI, wherever the render rectangle says. Unmapping the anchor (no buffer)
// hides everything nested in it.
// ---------------------------------------------------------------------------------------------

struct Globals {
  wl_subcompositor* subcompositor = nullptr;
  wl_shm* shm = nullptr;
};

void OnGlobal(void* data, wl_registry* registry, uint32_t name, const char* interface, uint32_t version) {
  (void)version;
  auto* globals = static_cast<Globals*>(data);
  if (std::strcmp(interface, "wl_subcompositor") == 0 && globals->subcompositor == nullptr) {
    globals->subcompositor =
        static_cast<wl_subcompositor*>(wl_registry_bind(registry, name, &wl_subcompositor_interface, 1));
  } else if (std::strcmp(interface, "wl_shm") == 0 && globals->shm == nullptr) {
    globals->shm = static_cast<wl_shm*>(wl_registry_bind(registry, name, &wl_shm_interface, 1));
  }
}

void OnGlobalRemove(void* data, wl_registry* registry, uint32_t name) {
  (void)data;
  (void)registry;
  (void)name;
}

const wl_registry_listener kRegistryListener = {OnGlobal, OnGlobalRemove};

class VideoAnchor {
 public:
  ~VideoAnchor() { Destroy(); }

  bool Create(GtkWidget* view, std::string* error) {
    view_ = view;
    GdkDisplay* gdk_display = gtk_widget_get_display(view);
    if (gdk_display == nullptr || !GDK_IS_WAYLAND_DISPLAY(gdk_display)) {
      *error = "Video needs a Wayland session (this looks like X11)";
      return false;
    }
    display_ = gdk_wayland_display_get_wl_display(GDK_WAYLAND_DISPLAY(gdk_display));
    wl_compositor* compositor = gdk_wayland_display_get_wl_compositor(GDK_WAYLAND_DISPLAY(gdk_display));
    GtkWidget* toplevel = gtk_widget_get_toplevel(view);
    GdkWindow* window = toplevel != nullptr ? gtk_widget_get_window(toplevel) : nullptr;
    if (display_ == nullptr || compositor == nullptr || window == nullptr || !GDK_IS_WAYLAND_WINDOW(window)) {
      *error = "The window has no Wayland surface yet";
      return false;
    }
    wl_surface* parent = gdk_wayland_window_get_wl_surface(GDK_WAYLAND_WINDOW(window));
    if (parent == nullptr) {
      *error = "The window has no Wayland surface yet";
      return false;
    }

    // Bind on a private queue so the roundtrip can't dispatch GDK's events from in here, then
    // hand the globals back to the default queue GDK drives.
    wl_event_queue* queue = wl_display_create_queue(display_);
    wl_registry* registry = wl_display_get_registry(display_);
    wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(registry), queue);
    Globals globals;
    wl_registry_add_listener(registry, &kRegistryListener, &globals);
    wl_display_roundtrip_queue(display_, queue);
    wl_registry_destroy(registry);
    if (globals.subcompositor != nullptr) wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(globals.subcompositor), nullptr);
    if (globals.shm != nullptr) wl_proxy_set_queue(reinterpret_cast<wl_proxy*>(globals.shm), nullptr);
    wl_event_queue_destroy(queue);
    subcompositor_ = globals.subcompositor;
    shm_ = globals.shm;
    if (subcompositor_ == nullptr || shm_ == nullptr) {
      *error = "The compositor offers no wl_subcompositor / wl_shm";
      Destroy();
      return false;
    }

    surface_ = wl_compositor_create_surface(compositor);
    // Input belongs to Flutter: an empty input region lets pointer and touch pass straight through.
    wl_region* empty = wl_compositor_create_region(compositor);
    wl_surface_set_input_region(surface_, empty);
    wl_region_destroy(empty);
    subsurface_ = wl_subcompositor_get_subsurface(subcompositor_, surface_, parent);
    wl_subsurface_place_below(subsurface_, parent);
    wl_subsurface_set_desync(subsurface_);

    if (!CreateBuffer(error)) {
      Destroy();
      return false;
    }
    RequestParentCommit();
    return true;
  }

  void Destroy() {
    if (buffer_ != nullptr) wl_buffer_destroy(buffer_);
    if (subsurface_ != nullptr) wl_subsurface_destroy(subsurface_);
    if (surface_ != nullptr) wl_surface_destroy(surface_);
    if (shm_ != nullptr) wl_shm_destroy(shm_);
    if (subcompositor_ != nullptr) wl_subcompositor_destroy(subcompositor_);
    buffer_ = nullptr;
    subsurface_ = nullptr;
    surface_ = nullptr;
    shm_ = nullptr;
    subcompositor_ = nullptr;
    if (display_ != nullptr) wl_display_flush(display_);
  }

  wl_display* display() const { return display_; }
  wl_surface* surface() const { return surface_; }

  // Mapped (carrying its buffer) or not; everything waylandsink nests in it follows.
  void SetVisible(bool visible) {
    if (surface_ == nullptr || visible == visible_) return;
    visible_ = visible;
    wl_surface_attach(surface_, visible ? buffer_ : nullptr, 0, 0);
    wl_surface_damage(surface_, 0, 0, 1, 1);
    wl_surface_commit(surface_);
    wl_display_flush(display_);
  }

  // Keeps the anchor at the Flutter view's origin inside the toplevel (a CSD titlebar or shadow
  // insets the view), so a render rectangle in view coordinates lands where Flutter drew the hole.
  void FollowView() {
    if (subsurface_ == nullptr || view_ == nullptr) return;
    GtkWidget* toplevel = gtk_widget_get_toplevel(view_);
    gint x = 0;
    gint y = 0;
    if (toplevel != nullptr) gtk_widget_translate_coordinates(view_, toplevel, 0, 0, &x, &y);
    if (x == x_ && y == y_ && positioned_) return;
    x_ = x;
    y_ = y;
    positioned_ = true;
    wl_subsurface_set_position(subsurface_, x, y);
    RequestParentCommit();
  }

 private:
  bool CreateBuffer(std::string* error) {
    // One transparent ARGB pixel. Subsurfaces need a buffer to be mapped at all.
    int fd = memfd_create("atlas-video-anchor", MFD_CLOEXEC);
    if (fd < 0 || ftruncate(fd, 4) != 0) {
      if (fd >= 0) close(fd);
      *error = "Couldn't allocate the video anchor buffer";
      return false;
    }
    void* data = mmap(nullptr, 4, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (data != MAP_FAILED) {
      std::memset(data, 0, 4);
      munmap(data, 4);
    }
    wl_shm_pool* pool = wl_shm_create_pool(shm_, fd, 4);
    buffer_ = wl_shm_pool_create_buffer(pool, 0, 1, 1, 4, WL_SHM_FORMAT_ARGB8888);
    wl_shm_pool_destroy(pool);
    close(fd);
    if (buffer_ == nullptr) {
      *error = "Couldn't create the video anchor buffer";
      return false;
    }
    return true;
  }

  // Subsurface position and stacking are parent state: they land when GTK next commits the window.
  void RequestParentCommit() {
    if (view_ != nullptr) gtk_widget_queue_draw(view_);
  }

  GtkWidget* view_ = nullptr;
  wl_display* display_ = nullptr;
  wl_subcompositor* subcompositor_ = nullptr;
  wl_shm* shm_ = nullptr;
  wl_surface* surface_ = nullptr;
  wl_subsurface* subsurface_ = nullptr;
  wl_buffer* buffer_ = nullptr;
  bool visible_ = false;
  bool positioned_ = false;
  gint x_ = 0;
  gint y_ = 0;
};

// ---------------------------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------------------------

std::string JsonEscape(const std::string& in) {
  std::string out;
  out.reserve(in.size() + 2);
  for (unsigned char c : in) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (c < 0x20) {
          char buf[8];
          g_snprintf(buf, sizeof(buf), "\\u%04x", c);
          out += buf;
        } else {
          out += static_cast<char>(c);
        }
    }
  }
  return out;
}

const char* LookupString(FlValue* args, const char* key) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return nullptr;
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING ? fl_value_get_string(value) : nullptr;
}

bool LookupBool(FlValue* args, const char* key, bool fallback) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return fallback;
  FlValue* value = fl_value_lookup_string(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL ? fl_value_get_bool(value) : fallback;
}

bool LookupNumber(FlValue* args, const char* key, double* out) {
  if (args == nullptr || fl_value_get_type(args) != FL_VALUE_TYPE_MAP) return false;
  FlValue* value = fl_value_lookup_string(args, key);
  if (value == nullptr) return false;
  if (fl_value_get_type(value) == FL_VALUE_TYPE_INT) {
    *out = static_cast<double>(fl_value_get_int(value));
    return true;
  }
  if (fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT) {
    *out = fl_value_get_float(value);
    return true;
  }
  return false;
}

// ---------------------------------------------------------------------------------------------
// Plugin
// ---------------------------------------------------------------------------------------------

struct Sidecar {
  std::string id, uri, title, language, codec;
  bool is_default = false;
  bool is_forced = false;
};

class GstAvPlugin {
 public:
  explicit GstAvPlugin(FlPluginRegistrar* registrar) : registrar_(FL_PLUGIN_REGISTRAR(g_object_ref(registrar))) {
    g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
    FlBinaryMessenger* messenger = fl_plugin_registrar_get_messenger(registrar);
    method_channel_ = fl_method_channel_new(messenger, kChannel, FL_METHOD_CODEC(codec));
    fl_method_channel_set_method_call_handler(method_channel_, &GstAvPlugin::OnMethodCall, this, nullptr);
    g_autofree gchar* events = g_strconcat(kChannel, "/events", nullptr);
    event_channel_ = fl_event_channel_new(messenger, events, FL_METHOD_CODEC(codec));
    fl_event_channel_set_stream_handlers(event_channel_, &GstAvPlugin::OnListen, &GstAvPlugin::OnCancel, this, nullptr);
  }

  void EmitLog(const char* level, const std::string& text) {
    g_autoptr(FlValue) data = fl_value_new_map();
    fl_value_set_string_take(data, "prefix", fl_value_new_string(kLogPrefix));
    fl_value_set_string_take(data, "level", fl_value_new_string(level));
    fl_value_set_string_take(data, "text", fl_value_new_string(text.c_str()));
    EmitEvent("log-message", data);
  }

 private:
  // ---- channel plumbing --------------------------------------------------------------------

  static FlMethodErrorResponse* OnListen(FlEventChannel*, FlValue*, gpointer user_data) {
    static_cast<GstAvPlugin*>(user_data)->listening_ = true;
    return nullptr;
  }

  static FlMethodErrorResponse* OnCancel(FlEventChannel*, FlValue*, gpointer user_data) {
    static_cast<GstAvPlugin*>(user_data)->listening_ = false;
    return nullptr;
  }

  void Send(FlValue* event) {
    if (!listening_) return;
    g_autoptr(GError) error = nullptr;
    if (!fl_event_channel_send(event_channel_, event, nullptr, &error) && error != nullptr) {
      g_warning("[AtlasGst] event send failed: %s", error->message);
    }
  }

  void EmitProperty(const char* name, FlValue* value /* taken */) {
    auto it = property_ids_.find(name);
    if (it == property_ids_.end()) {
      fl_value_unref(value);
      return;
    }
    g_autoptr(FlValue) event = fl_value_new_list();
    fl_value_append_take(event, fl_value_new_int(it->second));
    fl_value_append_take(event, value);
    Send(event);
  }

  void EmitBool(const char* name, bool value) { EmitProperty(name, fl_value_new_bool(value)); }
  void EmitDouble(const char* name, double value) { EmitProperty(name, fl_value_new_float(value)); }
  void EmitString(const char* name, const std::string& value) { EmitProperty(name, fl_value_new_string(value.c_str())); }

  void EmitEvent(const char* name, FlValue* data = nullptr) {
    g_autoptr(FlValue) event = fl_value_new_map();
    fl_value_set_string_take(event, "type", fl_value_new_string("event"));
    fl_value_set_string_take(event, "name", fl_value_new_string(name));
    if (data != nullptr) fl_value_set_string(event, "data", data);
    Send(event);
  }

  void EndFile(int reason, const std::string& message = {}) {
    g_autoptr(FlValue) data = fl_value_new_map();
    fl_value_set_string_take(data, "reason", fl_value_new_int(reason));
    if (!message.empty()) fl_value_set_string_take(data, "message", fl_value_new_string(message.c_str()));
    EmitEvent("end-file", data);
  }

  static void OnMethodCall(FlMethodChannel*, FlMethodCall* call, gpointer user_data) {
    auto* self = static_cast<GstAvPlugin*>(user_data);
    g_autoptr(FlMethodResponse) response = self->Handle(fl_method_call_get_name(call), fl_method_call_get_args(call));
    fl_method_call_respond(call, response, nullptr);
  }

  static FlMethodResponse* Ok(FlValue* value = nullptr) {
    return FL_METHOD_RESPONSE(fl_method_success_response_new(value));
  }

  static FlMethodResponse* Error(const char* code, const std::string& message) {
    return FL_METHOD_RESPONSE(fl_method_error_response_new(code, message.c_str(), nullptr));
  }

  FlMethodResponse* Handle(const gchar* method, FlValue* args) {
    if (std::strcmp(method, "initialize") == 0) {
      double instance = -1;
      LookupNumber(args, "instanceId", &instance);
      if (initialized_) {
        owner_ = static_cast<int64_t>(instance);
        g_autoptr(FlValue) yes = fl_value_new_bool(TRUE);
        return Ok(yes);
      }
      std::string error;
      if (!Initialize(&error)) {
        Log("error", "[AtlasGst] " + error);
        return Error("GST_INIT_FAILED", error);
      }
      owner_ = static_cast<int64_t>(instance);
      g_autoptr(FlValue) yes = fl_value_new_bool(TRUE);
      return Ok(yes);
    }
    if (std::strcmp(method, "dispose") == 0) {
      double instance = -1;
      if (LookupNumber(args, "instanceId", &instance) && owner_ >= 0 && static_cast<int64_t>(instance) != owner_) {
        return Ok();  // a stale dispose from a player that no longer owns the core
      }
      Dispose();
      return Ok();
    }
    if (std::strcmp(method, "isInitialized") == 0) {
      g_autoptr(FlValue) value = fl_value_new_bool(initialized_);
      return Ok(value);
    }
    if (std::strcmp(method, "isSupported") == 0) {
      // Asked once at startup, so the app only routes adaptive streams here when they can play.
      std::string reason;
      const bool supported = CanPlay(&reason);
      if (!supported) Log("info", "[AtlasGst] adaptive streaming unavailable: " + reason);
      g_autoptr(FlValue) value = fl_value_new_bool(supported);
      return Ok(value);
    }
    if (std::strcmp(method, "getPlayerType") == 0) {
      g_autoptr(FlValue) value = fl_value_new_string("gstreamer");
      return Ok(value);
    }
    if (std::strcmp(method, "observeProperty") == 0) {
      const char* name = LookupString(args, "name");
      double id = 0;
      if (name != nullptr && LookupNumber(args, "id", &id)) {
        property_ids_[name] = static_cast<int64_t>(id);
        Republish(name);
      }
      return Ok();
    }
    if (std::strcmp(method, "setVideoRect") == 0) {
      double left = 0, top = 0, right = 0, bottom = 0, dpr = 1;
      LookupNumber(args, "left", &left);
      LookupNumber(args, "top", &top);
      LookupNumber(args, "right", &right);
      LookupNumber(args, "bottom", &bottom);
      LookupNumber(args, "devicePixelRatio", &dpr);
      if (!(dpr >= 1.0) || dpr > 16.0) dpr = 1.0;
      // Physical pixels in the view -> surface-local (logical) units in the anchor.
      rect_x_ = static_cast<int>(std::floor(left / dpr));
      rect_y_ = static_cast<int>(std::floor(top / dpr));
      rect_w_ = std::max(1, static_cast<int>(std::ceil((right - left) / dpr)));
      rect_h_ = std::max(1, static_cast<int>(std::ceil((bottom - top) / dpr)));
      has_rect_ = true;
      ApplyRect();
      return Ok();
    }
    if (!initialized_) {
      // Transport before initialize (or after dispose): nothing to act on.
      g_autoptr(FlValue) empty = fl_value_new_map();
      return std::strcmp(method, "getStats") == 0 ? Ok(empty) : Ok();
    }
    if (std::strcmp(method, "open") == 0) {
      const char* uri = LookupString(args, "uri");
      if (uri == nullptr) return Error("INVALID_ARGS", "open needs a uri");
      double start_ms = 0;
      LookupNumber(args, "startPositionMs", &start_ms);
      Open(uri, args, static_cast<gint64>(start_ms), LookupBool(args, "autoPlay", true));
      return Ok();
    }
    if (std::strcmp(method, "play") == 0) {
      Play();
      return Ok();
    }
    if (std::strcmp(method, "pause") == 0) {
      Pause();
      return Ok();
    }
    if (std::strcmp(method, "stop") == 0) {
      Stop();
      return Ok();
    }
    if (std::strcmp(method, "seek") == 0) {
      double ms = 0;
      LookupNumber(args, "positionMs", &ms);
      Seek(static_cast<gint64>(ms));
      return Ok();
    }
    if (std::strcmp(method, "setVolume") == 0) {
      double volume = 100;
      LookupNumber(args, "volume", &volume);
      volume_ = std::clamp(volume, 0.0, 100.0);
      if (pipeline_ != nullptr) g_object_set(pipeline_, "volume", volume_ / 100.0, nullptr);
      return Ok();
    }
    if (std::strcmp(method, "setRate") == 0) {
      double rate = 1;
      LookupNumber(args, "rate", &rate);
      SetRate(rate);
      return Ok();
    }
    if (std::strcmp(method, "selectSubtitleTrack") == 0) {
      const char* id = LookupString(args, "trackId");
      selected_subtitle_.clear();
      for (const auto& sidecar : sidecars_) {
        if (id != nullptr && sidecar.id == id) selected_subtitle_ = sidecar.id;
      }
      EmitString("sid", selected_subtitle_.empty() ? "no" : selected_subtitle_);
      EmitTrackList();
      return Ok();
    }
    if (std::strcmp(method, "setVisible") == 0) {
      visible_ = LookupBool(args, "visible", true);
      anchor_.SetVisible(visible_ && has_rect_);
      return Ok();
    }
    if (std::strcmp(method, "updateFrame") == 0) {
      ApplyRect();
      if (sink_ != nullptr) gst_video_overlay_expose(GST_VIDEO_OVERLAY(sink_));
      return Ok();
    }
    if (std::strcmp(method, "setAbrLimits") == 0) {
      double value = 0;
      if (LookupNumber(args, "minBitrate", &value)) min_bitrate_ = static_cast<guint>(std::clamp(value, 0.0, 4.0e9));
      if (LookupNumber(args, "maxBitrate", &value)) max_bitrate_ = static_cast<guint>(std::clamp(value, 0.0, 4.0e9));
      if (LookupNumber(args, "maxBufferingMs", &value)) max_buffering_ms_ = static_cast<gint64>(value);
      ApplyAbrLimits();
      return Ok();
    }
    if (std::strcmp(method, "getStats") == 0) {
      return Ok(Stats());
    }
    // selectAudioTrack (one muxed track), setSubtitleRendering / setSubtitleStyle /
    // setSubtitleDelay (the app draws subtitles), setBoxFitMode / setVideoZoom (waylandsink always
    // letterboxes into the rectangle), and mpv-only calls.
    return Ok();
  }

  // ---- lifecycle ---------------------------------------------------------------------------

  // GStreamer with the elements this needs, on a Wayland session.
  static bool CanPlay(std::string* error) {
    GdkDisplay* display = gdk_display_get_default();
    if (display == nullptr || !GDK_IS_WAYLAND_DISPLAY(display)) {
      *error = "Video needs a Wayland session (this looks like X11)";
      return false;
    }
    if (!gst_is_initialized()) gst_init(nullptr, nullptr);
    for (const char* needed : {"playbin3", "hlsdemux2", "waylandsink"}) {
      GstElementFactory* factory = gst_element_factory_find(needed);
      if (factory == nullptr) {
        *error = std::string("GStreamer element '") + needed +
                 "' is missing (install the GStreamer good and bad plugins)";
        return false;
      }
      gst_object_unref(factory);
    }
    return true;
  }

  bool Initialize(std::string* error) {
    if (!CanPlay(error)) return false;
    PreferHardwareDecoders();

    FlView* view = fl_plugin_registrar_get_view(registrar_);
    if (view == nullptr) {
      *error = "No Flutter view to put video under";
      return false;
    }
    view_ = GTK_WIDGET(view);
    if (!anchor_.Create(view_, error)) return false;

    initialized_ = true;
    tick_source_ = g_timeout_add(250, &GstAvPlugin::OnTick, this);
    return true;
  }

  // GStreamer's VA-API decoders (AMD/Intel) aren't always ranked above the software ones; with
  // them first, playbin3 decodes on the GPU and hands waylandsink DMA-BUFs without a copy.
  // ATLAS_GST_SOFTWARE_DECODE=1 skips this, for a driver that misbehaves.
  static void PreferHardwareDecoders() {
    if (g_strcmp0(g_getenv("ATLAS_GST_SOFTWARE_DECODE"), "1") == 0) return;
    GstRegistry* registry = gst_registry_get();
    for (const char* name : {"vah264dec", "vah265dec", "vaav1dec", "vavp9dec"}) {
      GstPluginFeature* feature = gst_registry_lookup_feature(registry, name);
      if (feature == nullptr) continue;
      gst_plugin_feature_set_rank(feature, GST_RANK_PRIMARY + 1);
      gst_object_unref(feature);
    }
  }

  void Dispose() {
    TeardownPipeline();
    if (tick_source_ != 0) g_source_remove(tick_source_);
    tick_source_ = 0;
    anchor_.Destroy();
    initialized_ = false;
    property_ids_.clear();
    owner_ = -1;
  }

  void TeardownPipeline() {
    if (pipeline_ == nullptr) return;
    gst_element_set_state(pipeline_, GST_STATE_NULL);
    if (bus_watch_ != 0) g_source_remove(bus_watch_);
    bus_watch_ = 0;
    if (demux_ != nullptr) gst_object_unref(demux_);
    demux_ = nullptr;
    sink_ = nullptr;  // owned by the pipeline
    gst_object_unref(pipeline_);
    pipeline_ = nullptr;
  }

  // ---- open / transport ------------------------------------------------------------------

  void Open(const char* uri, FlValue* args, gint64 start_ms, bool auto_play) {
    TeardownPipeline();
    generation_++;
    file_loaded_ = false;
    seeking_ = false;
    start_seek_pending_ = start_ms > 0;
    start_ns_ = start_ms > 0 ? start_ms * GST_MSECOND : 0;
    want_play_ = auto_play;
    buffering_ = false;
    duration_known_ = false;
    // Open on the lowest rendition (a ceiling under all of them), the one the server started
    // transcoding when it handed out the playlist. Left alone, hlsdemux2 would climb by itself
    // before the Dart side has read the ladder, onto renditions that aren't transcoding yet. The
    // Dart side pins the level from here (and lifts all limits if the server can't warm up).
    min_bitrate_ = 0;
    max_bitrate_ = 1;
    max_buffering_ms_ = -1;

    headers_.clear();
    FlValue* headers = args != nullptr ? fl_value_lookup_string(args, "headers") : nullptr;
    if (headers != nullptr && fl_value_get_type(headers) == FL_VALUE_TYPE_MAP) {
      for (size_t i = 0; i < fl_value_get_length(headers); i++) {
        FlValue* key = fl_value_get_map_key(headers, i);
        FlValue* value = fl_value_get_map_value(headers, i);
        if (fl_value_get_type(key) == FL_VALUE_TYPE_STRING && fl_value_get_type(value) == FL_VALUE_TYPE_STRING) {
          headers_.emplace_back(fl_value_get_string(key), fl_value_get_string(value));
        }
      }
    }

    sidecars_.clear();
    selected_subtitle_.clear();
    FlValue* subs = args != nullptr ? fl_value_lookup_string(args, "externalSubtitles") : nullptr;
    if (subs != nullptr && fl_value_get_type(subs) == FL_VALUE_TYPE_LIST) {
      for (size_t i = 0; i < fl_value_get_length(subs); i++) {
        FlValue* raw = fl_value_get_list_value(subs, i);
        const char* sub_uri = LookupString(raw, "uri");
        if (sub_uri == nullptr || *sub_uri == '\0') continue;
        Sidecar sidecar;
        sidecar.id = std::to_string(sidecars_.size() + 1);
        sidecar.uri = sub_uri;
        if (const char* v = LookupString(raw, "title")) sidecar.title = v;
        if (const char* v = LookupString(raw, "language")) sidecar.language = v;
        if (const char* v = LookupString(raw, "codec")) sidecar.codec = v;
        sidecar.is_default = LookupBool(raw, "isDefault", false);
        sidecar.is_forced = LookupBool(raw, "isForced", false);
        sidecars_.push_back(std::move(sidecar));
      }
    }

    pipeline_ = gst_element_factory_make("playbin3", nullptr);
    sink_ = gst_element_factory_make("waylandsink", nullptr);
    if (pipeline_ == nullptr || sink_ == nullptr) {
      if (sink_ != nullptr) gst_object_unref(sink_);
      sink_ = nullptr;
      if (pipeline_ != nullptr) gst_object_unref(pipeline_);
      pipeline_ = nullptr;
      EndFile(4, "Couldn't create the GStreamer pipeline");
      return;
    }

    // waylandsink draws on our display connection, into the anchor under the Flutter surface.
    GstContext* context = gst_context_new("GstWlDisplayHandleContextType", TRUE);
    gst_structure_set(gst_context_writable_structure(context), "display", G_TYPE_POINTER, anchor_.display(), nullptr);
    gst_element_set_context(sink_, context);
    gst_context_unref(context);
    gst_video_overlay_set_window_handle(GST_VIDEO_OVERLAY(sink_), reinterpret_cast<guintptr>(anchor_.surface()));
    ApplyRect();

    guint flags = 0;
    g_object_get(pipeline_, "flags", &flags, nullptr);
    g_object_set(pipeline_, "uri", uri, "video-sink", sink_, "flags", flags & ~kPlayFlagText, "volume",
                 volume_ / 100.0, nullptr);
    g_signal_connect(pipeline_, "source-setup", G_CALLBACK(&GstAvPlugin::OnSourceSetup), this);
    g_signal_connect(pipeline_, "deep-element-added", G_CALLBACK(&GstAvPlugin::OnDeepElementAdded), this);

    GstBus* bus = gst_element_get_bus(pipeline_);
    bus_watch_ = gst_bus_add_watch(bus, &GstAvPlugin::OnBusMessage, this);
    gst_object_unref(bus);

    EmitBool("eof-reached", false);
    EmitBool("seekable", false);
    EmitBool("pause", !auto_play);
    EmitTrackList();
    EmitString("sid", "no");

    anchor_.SetVisible(visible_ && has_rect_);
    gst_element_set_state(pipeline_, GST_STATE_PAUSED);
  }

  void Play() {
    want_play_ = true;
    EmitBool("pause", false);
    if (pipeline_ == nullptr || !file_loaded_ || start_seek_pending_) return;
    if (eof_) {
      eof_ = false;
      EmitBool("eof-reached", false);
      gst_element_seek_simple(pipeline_, GST_FORMAT_TIME,
                              static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_KEY_UNIT), 0);
    }
    if (!buffering_) gst_element_set_state(pipeline_, GST_STATE_PLAYING);
  }

  void Pause() {
    want_play_ = false;
    EmitBool("pause", true);
    if (pipeline_ != nullptr) gst_element_set_state(pipeline_, GST_STATE_PAUSED);
  }

  void Stop() {
    want_play_ = false;
    TeardownPipeline();
    anchor_.SetVisible(false);
    EndFile(2);
  }

  void Seek(gint64 ms) {
    if (pipeline_ == nullptr) return;
    const gint64 target = std::max<gint64>(ms, 0) * GST_MSECOND;
    if (!file_loaded_) {
      // Not prerolled yet: the open's own start seek takes it.
      start_ns_ = target;
      start_seek_pending_ = target > 0;
      return;
    }
    eof_ = false;
    EmitBool("eof-reached", false);
    seeking_ = true;
    seek_target_ = target;
    gst_element_seek(pipeline_, rate_, GST_FORMAT_TIME,
                     static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE), GST_SEEK_TYPE_SET, target,
                     GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE);
  }

  void SetRate(double rate) {
    if (!(rate > 0.05) || rate > 8.0) return;
    rate_ = rate;
    if (pipeline_ == nullptr || !file_loaded_) return;
    gint64 position = 0;
    if (!gst_element_query_position(pipeline_, GST_FORMAT_TIME, &position)) return;
    gst_element_seek(pipeline_, rate_, GST_FORMAT_TIME,
                     static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE), GST_SEEK_TYPE_SET,
                     position, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE);
  }

  // ---- GStreamer callbacks -----------------------------------------------------------------

  // May run on a streaming thread: reads headers_ only.
  static void OnSourceSetup(GstElement*, GstElement* source, gpointer user_data) {
    auto* self = static_cast<GstAvPlugin*>(user_data);
    GObjectClass* klass = G_OBJECT_GET_CLASS(source);
    GstStructure* extra = gst_structure_new_empty("extra-headers");
    for (const auto& header : self->headers_) {
      if (g_ascii_strcasecmp(header.first.c_str(), "User-Agent") == 0) {
        if (g_object_class_find_property(klass, "user-agent") != nullptr) {
          g_object_set(source, "user-agent", header.second.c_str(), nullptr);
        }
      } else {
        gst_structure_set(extra, header.first.c_str(), G_TYPE_STRING, header.second.c_str(), nullptr);
      }
    }
    if (g_object_class_find_property(klass, "extra-headers") != nullptr && gst_structure_n_fields(extra) > 0) {
      g_object_set(source, "extra-headers", extra, nullptr);
    }
    gst_structure_free(extra);
  }

  // May run on a streaming thread: hand the demuxer to the main thread.
  static void OnDeepElementAdded(GstBin*, GstBin*, GstElement* element, gpointer user_data) {
    GstElementFactory* factory = gst_element_get_factory(element);
    if (factory == nullptr || g_strcmp0(gst_plugin_feature_get_name(GST_PLUGIN_FEATURE(factory)), "hlsdemux2") != 0) {
      return;
    }
    auto* self = static_cast<GstAvPlugin*>(user_data);
    struct Handoff {
      GstAvPlugin* self;
      GstElement* demux;
      uint64_t generation;
    };
    auto* handoff = new Handoff{self, GST_ELEMENT(gst_object_ref(element)), self->generation_};
    g_idle_add_full(
        G_PRIORITY_HIGH,
        [](gpointer data) -> gboolean {
          auto* h = static_cast<Handoff*>(data);
          if (h->generation == h->self->generation_ && h->self->pipeline_ != nullptr) {
            if (h->self->demux_ != nullptr) gst_object_unref(h->self->demux_);
            h->self->demux_ = GST_ELEMENT(gst_object_ref(h->demux));
            h->self->default_max_buffering_ns_ = DefaultBufferNs();
            h->self->ApplyAbrLimits();
          }
          gst_object_unref(h->demux);
          delete h;
          return G_SOURCE_REMOVE;
        },
        handoff, nullptr);
  }

  static gboolean OnBusMessage(GstBus*, GstMessage* message, gpointer user_data) {
    static_cast<GstAvPlugin*>(user_data)->HandleMessage(message);
    return G_SOURCE_CONTINUE;
  }

  void HandleMessage(GstMessage* message) {
    if (pipeline_ == nullptr) return;
    switch (GST_MESSAGE_TYPE(message)) {
      case GST_MESSAGE_ASYNC_DONE:
        OnAsyncDone();
        break;
      case GST_MESSAGE_EOS:
        eof_ = true;
        want_play_ = false;
        EmitBool("eof-reached", true);
        break;
      case GST_MESSAGE_ERROR: {
        g_autoptr(GError) error = nullptr;
        g_autofree gchar* debug = nullptr;
        gst_message_parse_error(message, &error, &debug);
        std::string text = error != nullptr ? error->message : "Playback failed";
        EmitLog("error", text + (debug != nullptr ? std::string(" (") + debug + ")" : ""));
        g_warning("[AtlasGst] %s", text.c_str());
        TeardownPipeline();
        EndFile(4, text);
        break;
      }
      case GST_MESSAGE_WARNING: {
        g_autoptr(GError) error = nullptr;
        gst_message_parse_warning(message, &error, nullptr);
        if (error != nullptr) EmitLog("warn", error->message);
        break;
      }
      case GST_MESSAGE_BUFFERING: {
        gint percent = 100;
        gst_message_parse_buffering(message, &percent);
        const bool buffering = percent < 100;
        if (buffering == buffering_) break;
        buffering_ = buffering;
        // The usual network-playback dance: pause while the queues refill, resume when full.
        if (file_loaded_ && !start_seek_pending_ && want_play_) {
          gst_element_set_state(pipeline_, buffering ? GST_STATE_PAUSED : GST_STATE_PLAYING);
        }
        EmitBool("paused-for-cache", buffering && want_play_);
        break;
      }
      case GST_MESSAGE_DURATION_CHANGED:
        QueryDuration();
        break;
      default:
        break;
    }
  }

  void OnAsyncDone() {
    if (!file_loaded_) {
      file_loaded_ = true;
      EmitEvent("file-loaded");
      QueryDuration();
      EmitTrackList();
      if (start_seek_pending_) {
        seeking_ = true;
        seek_target_ = start_ns_;
        gst_element_seek(pipeline_, rate_, GST_FORMAT_TIME,
                         static_cast<GstSeekFlags>(GST_SEEK_FLAG_FLUSH | GST_SEEK_FLAG_ACCURATE), GST_SEEK_TYPE_SET,
                         start_ns_, GST_SEEK_TYPE_NONE, GST_CLOCK_TIME_NONE);
        return;  // the seek's own ASYNC_DONE starts playback
      }
      if (want_play_) gst_element_set_state(pipeline_, GST_STATE_PLAYING);
      EmitEvent("playback-restart");
      return;
    }
    if (seeking_) {
      seeking_ = false;
      const bool initial = start_seek_pending_;
      start_seek_pending_ = false;
      EmitDouble("time-pos", static_cast<double>(seek_target_) / GST_SECOND);
      if (initial && want_play_ && !buffering_) gst_element_set_state(pipeline_, GST_STATE_PLAYING);
      EmitEvent("playback-restart");
    }
  }

  void QueryDuration() {
    gint64 duration = 0;
    if (pipeline_ != nullptr && gst_element_query_duration(pipeline_, GST_FORMAT_TIME, &duration) && duration > 0) {
      EmitDouble("duration", static_cast<double>(duration) / GST_SECOND);
      if (!duration_known_) {
        duration_known_ = true;
        EmitBool("seekable", true);
      }
    }
  }

  static gboolean OnTick(gpointer user_data) {
    auto* self = static_cast<GstAvPlugin*>(user_data);
    if (self->pipeline_ == nullptr || !self->file_loaded_ || self->seeking_) return G_SOURCE_CONTINUE;
    gint64 position = 0;
    if (gst_element_query_position(self->pipeline_, GST_FORMAT_TIME, &position) && position >= 0) {
      const double seconds = static_cast<double>(position) / GST_SECOND;
      self->EmitDouble("time-pos", seconds);
      self->EmitDouble("demuxer-cache-time", seconds + static_cast<double>(self->BufferedNs()) / GST_SECOND);
    }
    return G_SOURCE_CONTINUE;
  }

  // How far ahead video is buffered. hlsdemux2 reports "none" once it has downloaded through the
  // end of the stream; then it's everything up to the end.
  guint64 BufferedNs() const {
    guint64 level = 0;
    if (demux_ != nullptr) g_object_get(demux_, "current-level-time-video", &level, nullptr);
    if (level != GST_CLOCK_TIME_NONE && level < 24 * 3600 * GST_SECOND) return level;
    gint64 position = 0;
    gint64 duration = 0;
    if (pipeline_ != nullptr && gst_element_query_position(pipeline_, GST_FORMAT_TIME, &position) &&
        gst_element_query_duration(pipeline_, GST_FORMAT_TIME, &duration) && duration > position) {
      return static_cast<guint64>(duration - position);
    }
    return 0;
  }

  // ---- ABR limits ----------------------------------------------------------------------------

  // How far ahead to buffer (hlsdemux2's default is 30 s). hlsdemux2 switches renditions where its
  // buffer ends, so this is also how long a step up takes to show: 15 s keeps that short and still
  // rides out a hiccup. ATLAS_GST_BUFFER_SECONDS overrides it.
  static guint64 DefaultBufferNs() {
    const char* env = g_getenv("ATLAS_GST_BUFFER_SECONDS");
    const gint64 seconds = env != nullptr ? g_ascii_strtoll(env, nullptr, 10) : 0;
    return static_cast<guint64>(seconds >= 4 && seconds <= 120 ? seconds : 15) * GST_SECOND;
  }

  void ApplyAbrLimits() {
    if (demux_ == nullptr) return;
    g_object_set(demux_, "min-bitrate", min_bitrate_, "max-bitrate", max_bitrate_, nullptr);
    guint64 buffering = max_buffering_ms_ < 0 ? default_max_buffering_ns_
                                              : static_cast<guint64>(max_buffering_ms_) * GST_MSECOND;
    g_object_set(demux_, "max-buffering-time", buffering, nullptr);
  }

  // ---- layout --------------------------------------------------------------------------------

  void ApplyRect() {
    if (!has_rect_) return;
    anchor_.FollowView();
    if (sink_ != nullptr) {
      gst_video_overlay_set_render_rectangle(GST_VIDEO_OVERLAY(sink_), rect_x_, rect_y_, rect_w_, rect_h_);
    }
    anchor_.SetVisible(visible_);
  }

  // ---- tracks / stats ------------------------------------------------------------------------

  void Republish(const char* name) {
    if (std::strcmp(name, "pause") == 0) EmitBool("pause", !want_play_);
    if (std::strcmp(name, "volume") == 0) EmitDouble("volume", volume_);
    if (std::strcmp(name, "speed") == 0) EmitDouble("speed", rate_);
    if (std::strcmp(name, "track-list") == 0) EmitTrackList();
  }

  void EmitTrackList() {
    std::string json = R"([{"id":"1","type":"video","selected":true},{"id":"1","type":"audio","selected":true,"default":true})";
    for (const auto& s : sidecars_) {
      json += R"(,{"id":")" + JsonEscape(s.id) + R"(","type":"sub","external":true,"external-filename":")" +
              JsonEscape(s.uri) + R"(","default":)" + (s.is_default ? "true" : "false") + R"(,"forced":)" +
              (s.is_forced ? "true" : "false") + R"(,"selected":)" + (s.id == selected_subtitle_ ? "true" : "false");
      if (!s.title.empty()) json += R"(,"title":")" + JsonEscape(s.title) + "\"";
      if (!s.language.empty()) json += R"(,"lang":")" + JsonEscape(s.language) + "\"";
      if (!s.codec.empty()) json += R"(,"codec":")" + JsonEscape(s.codec) + "\"";
      json += "}";
    }
    json += "]";
    EmitString("track-list", json);
    EmitString("aid", "1");
  }

  // AVPlayer/ExoPlayer-shaped stats, plus what the Dart ABR logic reads.
  FlValue* Stats() {
    FlValue* out = fl_value_new_map();
    fl_value_set_string_take(out, "playerType", fl_value_new_string("gstreamer"));
    if (pipeline_ == nullptr) return out;
    gint64 position = 0;
    if (gst_element_query_position(pipeline_, GST_FORMAT_TIME, &position) && position >= 0) {
      fl_value_set_string_take(out, "positionMs", fl_value_new_int(position / GST_MSECOND));
    }
    fl_value_set_string_take(out, "totalBufferedDurationMs", fl_value_new_int(static_cast<int64_t>(BufferedNs() / GST_MSECOND)));
    fl_value_set_string_take(out, "buffering", fl_value_new_bool(buffering_ && want_play_));
    fl_value_set_string_take(out, "playing", fl_value_new_bool(want_play_ && !buffering_ && file_loaded_));
    if (demux_ != nullptr) {
      guint bandwidth = 0;
      g_object_get(demux_, "current-bandwidth", &bandwidth, nullptr);
      if (bandwidth > 0) fl_value_set_string_take(out, "bandwidthEstimate", fl_value_new_int(bandwidth));
    }
    if (sink_ != nullptr) {
      GstPad* pad = gst_element_get_static_pad(sink_, "sink");
      if (pad != nullptr) {
        GstCaps* caps = gst_pad_get_current_caps(pad);
        if (caps != nullptr) {
          const GstStructure* s = gst_caps_get_structure(caps, 0);
          gint width = 0, height = 0, fps_n = 0, fps_d = 1;
          if (gst_structure_get_int(s, "width", &width)) fl_value_set_string_take(out, "videoWidth", fl_value_new_int(width));
          if (gst_structure_get_int(s, "height", &height)) fl_value_set_string_take(out, "videoHeight", fl_value_new_int(height));
          if (gst_structure_get_fraction(s, "framerate", &fps_n, &fps_d) && fps_n > 0 && fps_d > 0) {
            fl_value_set_string_take(out, "videoFps", fl_value_new_float(static_cast<double>(fps_n) / fps_d));
          }
          GstCapsFeatures* features = gst_caps_get_features(caps, 0);
          const bool gpu = features != nullptr && (gst_caps_features_contains(features, "memory:DMABuf") ||
                                                   gst_caps_features_contains(features, "memory:VAMemory"));
          std::string name = std::string("GStreamer HLS, ") + (gpu ? "GPU decode" : "CPU decode");
          fl_value_set_string_take(out, "videoDecoderName", fl_value_new_string(name.c_str()));
          gst_caps_unref(caps);
        }
        gst_object_unref(pad);
      }
    }
    return out;
  }

  // ---- state ---------------------------------------------------------------------------------

  FlPluginRegistrar* registrar_;
  FlMethodChannel* method_channel_ = nullptr;
  FlEventChannel* event_channel_ = nullptr;
  bool listening_ = false;
  std::map<std::string, int64_t> property_ids_;
  int64_t owner_ = -1;

  bool initialized_ = false;
  GtkWidget* view_ = nullptr;
  VideoAnchor anchor_;
  guint tick_source_ = 0;

  GstElement* pipeline_ = nullptr;
  GstElement* sink_ = nullptr;
  GstElement* demux_ = nullptr;
  guint bus_watch_ = 0;
  uint64_t generation_ = 0;
  std::vector<std::pair<std::string, std::string>> headers_;

  bool file_loaded_ = false;
  bool want_play_ = false;
  bool buffering_ = false;
  bool seeking_ = false;
  bool start_seek_pending_ = false;
  bool eof_ = false;
  bool duration_known_ = false;
  gint64 start_ns_ = 0;
  gint64 seek_target_ = 0;
  double rate_ = 1.0;
  double volume_ = 100.0;

  guint min_bitrate_ = 0;
  guint max_bitrate_ = 0;
  gint64 max_buffering_ms_ = -1;
  guint64 default_max_buffering_ns_ = 15 * GST_SECOND;

  bool visible_ = true;
  bool has_rect_ = false;
  int rect_x_ = 0, rect_y_ = 0, rect_w_ = 1, rect_h_ = 1;

  std::vector<Sidecar> sidecars_;
  std::string selected_subtitle_;
};

GstAvPlugin* g_plugin = nullptr;

void Log(const char* level, const std::string& text) {
  if (g_strcmp0(level, "error") == 0) {
    g_warning("%s", text.c_str());
  } else {
    g_message("%s", text.c_str());
  }
  if (g_plugin != nullptr) g_plugin->EmitLog(level, text);
}

}  // namespace

void gst_av_plugin_register_with_registrar(FlPluginRegistrar* registrar) {
  if (g_plugin == nullptr) g_plugin = new GstAvPlugin(registrar);
}
