#ifndef ATLAS_LINUX_GST_AV_PLUGIN_H_
#define ATLAS_LINUX_GST_AV_PLUGIN_H_

#include <flutter_linux/flutter_linux.h>

G_BEGIN_DECLS

/// Atlas: GStreamer video backend for adaptive streaming on Linux.
///
/// mpv can't switch HLS renditions; GStreamer's hlsdemux2 can, at segment boundaries and without
/// throwing away what it has buffered. This plays Atlas adaptive streams only (direct play, downloads
/// and live TV stay on mpv), on the channel `com.atlas/gst_player`, speaking the same protocol as
/// the AVPlayer plugin on Apple, so the Dart side (`PlayerGStreamer`) shares its code.
///
/// Which rendition plays is the Dart side's call (`AtlasGstAbr`): it pins hlsdemux2 to one level
/// through `setAbrLimits`, and only moves the pin up once the server has warmed the level.
///
/// Video goes to a Wayland subsurface below the Flutter surface, the same place as the mpv plane:
/// a 1x1 transparent anchor surface that waylandsink nests its own video surfaces in.
void gst_av_plugin_register_with_registrar(FlPluginRegistrar* registrar);

G_END_DECLS

#endif  // ATLAS_LINUX_GST_AV_PLUGIN_H_
