#include "media_controls.h"
#include "channel_utils.h"
#include <algorithm>
#include <cmath>

namespace {
constexpr const char* kPath = "/org/mpris/MediaPlayer2";
constexpr const char* kRoot = "org.mpris.MediaPlayer2";
constexpr const char* kPlayer = "org.mpris.MediaPlayer2.Player";
constexpr const char* kXml = R"XML(
<node>
 <interface name="org.mpris.MediaPlayer2">
  <method name="Raise"/><method name="Quit"/>
  <property name="CanQuit" type="b" access="read"/>
  <property name="CanRaise" type="b" access="read"/>
  <property name="HasTrackList" type="b" access="read"/>
  <property name="Identity" type="s" access="read"/>
  <property name="DesktopEntry" type="s" access="read"/>
  <property name="SupportedUriSchemes" type="as" access="read"/>
  <property name="SupportedMimeTypes" type="as" access="read"/>
 </interface>
 <interface name="org.mpris.MediaPlayer2.Player">
  <method name="Next"/><method name="Previous"/><method name="Pause"/>
  <method name="PlayPause"/><method name="Stop"/><method name="Play"/>
  <method name="Seek"><arg name="Offset" type="x" direction="in"/></method>
  <method name="SetPosition"><arg name="TrackId" type="o" direction="in"/>
   <arg name="Position" type="x" direction="in"/></method>
  <method name="OpenUri"><arg name="Uri" type="s" direction="in"/></method>
  <signal name="Seeked"><arg name="Position" type="x"/></signal>
  <property name="PlaybackStatus" type="s" access="read"/>
  <property name="LoopStatus" type="s" access="readwrite"/>
  <property name="Rate" type="d" access="readwrite"/>
  <property name="Shuffle" type="b" access="readwrite"/>
  <property name="Metadata" type="a{sv}" access="read"/>
  <property name="Volume" type="d" access="readwrite"/>
  <property name="Position" type="x" access="read">
   <annotation name="org.freedesktop.DBus.Property.EmitsChangedSignal" value="false"/>
  </property>
  <property name="MinimumRate" type="d" access="read"/>
  <property name="MaximumRate" type="d" access="read"/>
  <property name="CanGoNext" type="b" access="read"/>
  <property name="CanGoPrevious" type="b" access="read"/>
  <property name="CanPlay" type="b" access="read"/>
  <property name="CanPause" type="b" access="read"/>
  <property name="CanSeek" type="b" access="read"/>
  <property name="CanControl" type="b" access="read"/>
 </interface>
</node>)XML";

struct ControlReply {
  GDBusMethodInvocation* invocation;
  GDBusConnection* bus;
  gint64 seek_position;
  std::string method;
};

void control_complete(GObject* source, GAsyncResult* result, gpointer data) {
  auto* reply = static_cast<ControlReply*>(data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response = fl_method_channel_invoke_method_finish(
      FL_METHOD_CHANNEL(source), result, &error);
  bool success = response != nullptr && FL_IS_METHOD_SUCCESS_RESPONSE(response);
  if (success) {
    FlValue* value = fl_method_success_response_get_result(FL_METHOD_SUCCESS_RESPONSE(response));
    success = value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL && fl_value_get_bool(value);
  }
  if (!success) g_warning("Dart media control was not completed: %s", reply->method.c_str());
  if (reply->invocation != nullptr) {
    if (success) g_dbus_method_invocation_return_value(reply->invocation, nullptr);
    else g_dbus_method_invocation_return_dbus_error(reply->invocation,
        "org.mpris.MediaPlayer2.Error.Failed", "播放控制尚未准备好，请稍后重试");
  }
  if (success && reply->seek_position >= 0 && reply->bus != nullptr) {
    g_dbus_connection_emit_signal(reply->bus, nullptr, kPath, kPlayer, "Seeked",
                                  g_variant_new("(x)", reply->seek_position), nullptr);
  }
  g_clear_object(&reply->invocation);
  g_clear_object(&reply->bus);
  delete reply;
}
}  // namespace

MediaControls::MediaControls(FlBinaryMessenger* messenger, std::function<void()> raise,
                             std::function<void()> quit)
    : raise_(std::move(raise)), quit_(std::move(quit)) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger, "qingting/media_controls", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(channel_, FlutterCall, this, nullptr);
  g_autoptr(GError) error = nullptr;
  bus_ = g_bus_get_sync(G_BUS_TYPE_SESSION, nullptr, &error);
  if (bus_ == nullptr) {
    g_warning("MPRIS session bus unavailable: %s", error->message);
    return;
  }
  node_ = g_dbus_node_info_new_for_xml(kXml, nullptr);
  static const GDBusInterfaceVTable table = {BusCall, GetProperty, SetProperty, {nullptr}};
  root_registration_ = g_dbus_connection_register_object(bus_, kPath, node_->interfaces[0], &table, this, nullptr, &error);
  if (root_registration_ != 0)
    player_registration_ = g_dbus_connection_register_object(bus_, kPath, node_->interfaces[1], &table, this, nullptr, &error);
  if (root_registration_ == 0 || player_registration_ == 0) {
    g_warning("MPRIS registration failed: %s", error->message);
    return;
  }
  owner_ = g_bus_own_name_on_connection(bus_, "org.mpris.MediaPlayer2.qingting",
                                       G_BUS_NAME_OWNER_FLAGS_NONE, nullptr, nullptr, nullptr, nullptr);
}

MediaControls::~MediaControls() {
  fl_method_channel_set_method_call_handler(channel_, nullptr, nullptr, nullptr);
  if (owner_ != 0) g_bus_unown_name(owner_);
  if (root_registration_ != 0) g_dbus_connection_unregister_object(bus_, root_registration_);
  if (player_registration_ != 0) g_dbus_connection_unregister_object(bus_, player_registration_);
  g_clear_pointer(&node_, g_dbus_node_info_unref);
  g_clear_object(&bus_);
  g_clear_object(&channel_);
}

void MediaControls::Invoke(const char* method, FlValue* args, GDBusMethodInvocation* reply,
                            gint64 seek_position) {
  auto* context = new ControlReply{reply == nullptr ? nullptr : G_DBUS_METHOD_INVOCATION(g_object_ref(reply)),
      bus_ == nullptr ? nullptr : G_DBUS_CONNECTION(g_object_ref(bus_)), seek_position, method};
  fl_method_channel_invoke_method(channel_, method, args, nullptr, control_complete, context);
}

void MediaControls::Action(const char* action) { Invoke(action, nullptr); }

gint64 MediaControls::Position() const {
  gint64 elapsed = playing_ ? std::max<gint64>(0, g_get_monotonic_time() - updated_at_) : 0;
  return std::min(duration_, position_ + elapsed);
}

GVariant* MediaControls::Metadata() const {
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  if (!title_.empty()) {
    const char* artists[] = {artist_.c_str(), nullptr};
    g_variant_builder_add(&b, "{sv}", "mpris:trackid", g_variant_new_object_path(track_.c_str()));
    g_variant_builder_add(&b, "{sv}", "mpris:length", g_variant_new_int64(duration_));
    g_variant_builder_add(&b, "{sv}", "xesam:title", g_variant_new_string(title_.c_str()));
    g_variant_builder_add(&b, "{sv}", "xesam:artist", g_variant_new_strv(artists, -1));
    g_variant_builder_add(&b, "{sv}", "xesam:album", g_variant_new_string(album_.c_str()));
    if (!cover_.empty()) g_variant_builder_add(&b, "{sv}", "mpris:artUrl", g_variant_new_string(cover_.c_str()));
  }
  return g_variant_builder_end(&b);
}

void MediaControls::Update(FlValue* args) {
  title_ = channel_string(args, "title");
  artist_ = channel_string(args, "artist");
  album_ = channel_string(args, "album");
  g_autofree gchar* digest = g_compute_checksum_for_string(G_CHECKSUM_SHA256, channel_string(args, "trackId"), -1);
  track_ = std::string("/org/mpris/MediaPlayer2/track/") + digest;
  const char* path = channel_string(args, "coverFilePath");
  g_autofree gchar* cover = path[0] == '\0' ? nullptr : g_filename_to_uri(path, nullptr, nullptr);
  cover_ = cover == nullptr ? "" : cover;
  duration_ = std::max<gint64>(0, channel_number(args, "durationMs") * 1000);
  position_ = std::max<gint64>(0, channel_number(args, "positionMs") * 1000);
  updated_at_ = g_get_monotonic_time();
  playing_ = channel_bool(args, "isPlaying");
  opened_ = channel_bool(args, "isOpened", true);
  previous_ = channel_bool(args, "canPlayPrevious");
  next_ = channel_bool(args, "canPlayNext");
  shuffle_ = channel_bool(args, "shuffle");
  volume_ = std::max(0., std::min(1., channel_number(args, "volume", 1)));
  loop_ = channel_string(args, "loopStatus");
  if (loop_ != "Track" && loop_ != "Playlist") loop_ = "None";
  Changed();
}

void MediaControls::FlutterCall(FlMethodChannel*, FlMethodCall* call, gpointer data) {
  auto* self = static_cast<MediaControls*>(data);
  const char* method = fl_method_call_get_name(call);
  if (g_str_equal(method, "update")) self->Update(fl_method_call_get_args(call));
  else if (g_str_equal(method, "state")) {
    FlValue* args = fl_method_call_get_args(call);
    self->volume_ = std::max(0., std::min(1., channel_number(args, "volume", 1)));
    self->shuffle_ = channel_bool(args, "shuffle");
    self->loop_ = channel_string(args, "loopStatus");
    if (self->loop_ != "Track" && self->loop_ != "Playlist") self->loop_ = "None";
    self->Changed();
  }
  else if (g_str_equal(method, "hide")) {
    self->playing_ = self->opened_ = self->previous_ = self->next_ = false;
    self->title_.clear();
    self->track_ = "/org/mpris/MediaPlayer2/TrackList/NoTrack";
    self->position_ = self->duration_ = 0;
    self->Changed();
  } else { fl_method_call_respond_not_implemented(call, nullptr); return; }
  g_autoptr(FlValue) result = fl_value_new_bool(TRUE);
  fl_method_call_respond_success(call, result, nullptr);
}

GVariant* MediaControls::GetProperty(GDBusConnection*, const char*, const char*,
                                    const char* interface, const char* name, GError**, gpointer data) {
  auto* self = static_cast<MediaControls*>(data);
  if (g_str_equal(interface, kRoot)) {
    if (g_str_equal(name, "Identity")) return g_variant_new_string("青听");
    if (g_str_equal(name, "DesktopEntry")) return g_variant_new_string("com.pobb.qingting");
    if (g_str_equal(name, "SupportedUriSchemes") || g_str_equal(name, "SupportedMimeTypes"))
      return g_variant_new_strv(nullptr, 0); // OpenUri is intentionally unsupported.
    return g_variant_new_boolean(!g_str_equal(name, "HasTrackList"));
  }
  if (g_str_equal(name, "PlaybackStatus")) return g_variant_new_string(
      self->playing_ ? "Playing" : self->opened_ ? "Paused" : "Stopped");
  if (g_str_equal(name, "LoopStatus")) return g_variant_new_string(self->loop_.c_str());
  if (g_str_equal(name, "Shuffle")) return g_variant_new_boolean(self->shuffle_);
  if (g_str_equal(name, "Metadata")) return self->Metadata();
  if (g_str_equal(name, "Volume")) return g_variant_new_double(self->volume_);
  if (g_str_equal(name, "Position")) return g_variant_new_int64(self->Position());
  if (g_str_equal(name, "Rate") || g_str_equal(name, "MinimumRate") || g_str_equal(name, "MaximumRate"))
    return g_variant_new_double(1.);
  if (g_str_equal(name, "CanGoNext")) return g_variant_new_boolean(self->next_);
  if (g_str_equal(name, "CanGoPrevious")) return g_variant_new_boolean(self->previous_);
  if (g_str_equal(name, "CanControl")) return g_variant_new_boolean(TRUE);
  if (g_str_equal(name, "CanSeek")) return g_variant_new_boolean(self->opened_ && self->duration_ > 0);
  return g_variant_new_boolean(!self->title_.empty());
}

gboolean MediaControls::SetProperty(GDBusConnection*, const char*, const char*, const char*,
                                    const char* name, GVariant* value, GError** error, gpointer data) {
  auto* self = static_cast<MediaControls*>(data);
  if (g_str_equal(name, "Rate") && g_variant_get_double(value) == 1.) return TRUE;
  g_autoptr(FlValue) args = fl_value_new_map();
  fl_value_set_string_take(args, "property", fl_value_new_string(name));
  if (g_str_equal(name, "Volume") && std::isfinite(g_variant_get_double(value)))
    fl_value_set_string_take(args, "value", fl_value_new_float(std::max(0., std::min(1., g_variant_get_double(value)))));
  else if (g_str_equal(name, "Shuffle"))
    fl_value_set_string_take(args, "value", fl_value_new_bool(g_variant_get_boolean(value)));
  else if (g_str_equal(name, "LoopStatus") &&
           (g_str_equal(g_variant_get_string(value, nullptr), "None") ||
            g_str_equal(g_variant_get_string(value, nullptr), "Track") ||
            g_str_equal(g_variant_get_string(value, nullptr), "Playlist")))
    fl_value_set_string_take(args, "value", fl_value_new_string(g_variant_get_string(value, nullptr)));
  else {
    g_set_error_literal(error, G_DBUS_ERROR, G_DBUS_ERROR_INVALID_ARGS, "Unsupported property value");
    return FALSE;
  }
  self->Invoke("setProperty", args);
  return TRUE;
}

void MediaControls::Changed() {
  if (bus_ == nullptr) return;
  GVariantBuilder b;
  g_variant_builder_init(&b, G_VARIANT_TYPE("a{sv}"));
  for (const char* name : {"PlaybackStatus", "LoopStatus", "Shuffle", "Metadata", "Volume",
                          "CanGoNext", "CanGoPrevious", "CanPlay", "CanPause", "CanSeek"}) {
    g_variant_builder_add(&b, "{sv}", name, GetProperty(nullptr, nullptr, nullptr, kPlayer, name, nullptr, this));
  }
  g_dbus_connection_emit_signal(bus_, nullptr, kPath, "org.freedesktop.DBus.Properties", "PropertiesChanged",
      g_variant_new("(sa{sv}as)", kPlayer, &b, nullptr), nullptr);
}

void MediaControls::BusCall(GDBusConnection*, const char*, const char*, const char* interface,
                            const char* method, GVariant* params, GDBusMethodInvocation* reply, gpointer data) {
  auto* self = static_cast<MediaControls*>(data);
  if (g_str_equal(interface, kRoot)) {
    g_dbus_method_invocation_return_value(reply, nullptr);
    if (g_str_equal(method, "Raise")) self->raise_();
    else self->quit_();
    return;
  }
  const char* action = nullptr;
  if (g_str_equal(method, "Play")) action = "play";
  else if (g_str_equal(method, "Pause")) action = "pause";
  else if (g_str_equal(method, "Stop")) action = "stop";
  else if (g_str_equal(method, "PlayPause")) action = "toggle";
  else if (g_str_equal(method, "Next")) action = "next";
  else if (g_str_equal(method, "Previous")) action = "previous";
  if (action != nullptr) { self->Invoke(action, nullptr, reply); return; }
  if (g_str_equal(method, "Seek") || g_str_equal(method, "SetPosition")) {
    gint64 position;
    if (!self->opened_ || self->duration_ <= 0) { g_dbus_method_invocation_return_value(reply, nullptr); return; }
    if (g_str_equal(method, "Seek")) {
      gint64 offset; g_variant_get(params, "(x)", &offset);
      const long double target = static_cast<long double>(self->Position()) + offset;
      if (target >= self->duration_) { self->Invoke("next", nullptr, reply); return; }
      position = static_cast<gint64>(std::max(0.L, target));
    } else {
      const char* track; g_variant_get(params, "(&ox)", &track, &position);
      if (self->track_ != track || position < 0 || position > self->duration_) {
        g_dbus_method_invocation_return_value(reply, nullptr); return;
      }
    }
    position = std::min(position, std::max<gint64>(0, self->duration_ - 250000));
    g_autoptr(FlValue) args = fl_value_new_map();
    fl_value_set_string_take(args, "positionMs", fl_value_new_int(position / 1000));
    self->Invoke("seek", args, reply, position);
    return;
  }
  g_dbus_method_invocation_return_error_literal(reply, G_DBUS_ERROR, G_DBUS_ERROR_NOT_SUPPORTED, "OpenUri is not supported");
}
