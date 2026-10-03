#include "audio_route_monitor.h"
#include <unistd.h>

AudioRouteMonitor::AudioRouteMonitor(FlBinaryMessenger* messenger) {
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  channel_ = fl_method_channel_new(messenger, "qingting/audio_route", FL_METHOD_CODEC(codec));
  loop_ = pa_glib_mainloop_new(nullptr);
  Connect();
}

AudioRouteMonitor::~AudioRouteMonitor() {
  if (refresh_timer_ != 0) g_source_remove(refresh_timer_);
  if (reconnect_timer_ != 0) g_source_remove(reconnect_timer_);
  if (context_ != nullptr) {
    pa_context_set_state_callback(context_, nullptr, nullptr);
    pa_context_set_subscribe_callback(context_, nullptr, nullptr);
    pa_context_disconnect(context_);
    pa_context_unref(context_);
  }
  pa_glib_mainloop_free(loop_);
  g_clear_object(&channel_);
}

void AudioRouteMonitor::Connect() {
  if (context_ != nullptr) {
    pa_context_set_state_callback(context_, nullptr, nullptr);
    pa_context_disconnect(context_);
    pa_context_unref(context_);
  }
  pending_ = 0;
  context_ = pa_context_new(pa_glib_mainloop_get_api(loop_), "青听音频设备监听");
  pa_context_set_state_callback(context_, StateChanged, this);
  pa_context_connect(context_, nullptr, PA_CONTEXT_NOAUTOSPAWN, nullptr);
}

void AudioRouteMonitor::Pause() {
  fl_method_channel_invoke_method(channel_, "bluetoothDisconnectedOrSwitched", nullptr, nullptr, nullptr, nullptr);
}

void AudioRouteMonitor::StateChanged(pa_context* context, void* data) {
  auto* self = static_cast<AudioRouteMonitor*>(data);
  const auto state = pa_context_get_state(context);
  if (state == PA_CONTEXT_READY) {
    pa_context_set_subscribe_callback(context, Subscription, self);
    auto* operation = pa_context_subscribe(context,
        static_cast<pa_subscription_mask_t>(PA_SUBSCRIPTION_MASK_SINK |
            PA_SUBSCRIPTION_MASK_SINK_INPUT), nullptr, nullptr);
    if (operation != nullptr) pa_operation_unref(operation);
    self->Schedule();
  } else if (state == PA_CONTEXT_FAILED || state == PA_CONTEXT_TERMINATED) {
    if (!self->active_bluetooth_.empty()) self->Pause();
    self->active_bluetooth_.clear();
    self->primed_ = false;
    self->pending_ = 0;
    if (self->refresh_timer_ != 0) { g_source_remove(self->refresh_timer_); self->refresh_timer_ = 0; }
    if (self->reconnect_timer_ == 0) {
      self->reconnect_timer_ = g_timeout_add_seconds(3, +[](gpointer value) -> gboolean {
        auto* monitor = static_cast<AudioRouteMonitor*>(value);
        monitor->reconnect_timer_ = 0;
        monitor->Connect();
        return G_SOURCE_REMOVE;
      }, self);
    }
  }
}

void AudioRouteMonitor::Subscription(pa_context*, pa_subscription_event_type_t, uint32_t, void* data) {
  static_cast<AudioRouteMonitor*>(data)->Schedule();
}

void AudioRouteMonitor::Schedule() {
  if (pending_ != 0) { dirty_ = true; return; }
  if (refresh_timer_ != 0) return;
  refresh_timer_ = g_timeout_add(100, +[](gpointer data) -> gboolean {
    auto* self = static_cast<AudioRouteMonitor*>(data);
    self->refresh_timer_ = 0;
    self->Refresh();
    return G_SOURCE_REMOVE;
  }, this);
}

void AudioRouteMonitor::Refresh() {
  if (pa_context_get_state(context_) != PA_CONTEXT_READY) return;
  pending_ = 2;
  dirty_ = snapshot_failed_ = false;
  sinks_.clear(); inputs_.clear();
  pa_operation* operations[] = {
    pa_context_get_sink_info_list(context_, Sink, this),
    pa_context_get_sink_input_info_list(context_, Input, this),
  };
  for (auto* operation : operations) {
    if (operation != nullptr) pa_operation_unref(operation);
    else { snapshot_failed_ = true; PartDone(); }
  }
}

void AudioRouteMonitor::Sink(pa_context*, const pa_sink_info* info, int eol, void* data) {
  auto* self = static_cast<AudioRouteMonitor*>(data);
  if (eol != 0) {
    if (eol < 0) self->snapshot_failed_ = true;
    self->PartDone(); return;
  }
  const char* bus = pa_proplist_gets(info->proplist, "device.bus");
  const bool bluetooth = g_strcmp0(bus, "bluetooth") == 0 ||
      pa_proplist_gets(info->proplist, "api.bluez5.address") != nullptr ||
      pa_proplist_gets(info->proplist, "bluez.path") != nullptr ||
      g_str_has_prefix(info->name, "bluez_") || g_str_has_prefix(info->name, "bluez_output.");
  self->sinks_[info->index] = {info->name, bluetooth};
}

void AudioRouteMonitor::Input(pa_context*, const pa_sink_input_info* info, int eol, void* data) {
  auto* self = static_cast<AudioRouteMonitor*>(data);
  if (eol != 0) {
    if (eol < 0) self->snapshot_failed_ = true;
    self->PartDone(); return;
  }
  const char* pid = pa_proplist_gets(info->proplist, PA_PROP_APPLICATION_PROCESS_ID);
  if (pid != nullptr && std::to_string(getpid()) == pid) self->inputs_.insert(info->sink);
}

void AudioRouteMonitor::PartDone() {
  if (pending_ <= 0 || --pending_ != 0) return;
  if (!snapshot_failed_) {
    std::set<std::string> active;
    for (const auto& sink : sinks_) {
      const bool used = inputs_.count(sink.first) != 0;
      if (used && sink.second.second) active.insert(sink.second.first);
    }
    if (primed_ && !active_bluetooth_.empty() && active != active_bluetooth_) Pause();
    active_bluetooth_ = std::move(active);
    primed_ = true;
  }
  if (dirty_) Schedule();
}
