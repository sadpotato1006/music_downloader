#ifndef QINGTING_MEDIA_CONTROLS_H
#define QINGTING_MEDIA_CONTROLS_H

#include <flutter_linux/flutter_linux.h>
#include <functional>
#include <string>

class MediaControls {
 public:
  MediaControls(FlBinaryMessenger* messenger, std::function<void()> raise,
                std::function<void()> quit);
  ~MediaControls();
  void Action(const char* action);
  bool playing() const { return playing_; }

 private:
  static void FlutterCall(FlMethodChannel*, FlMethodCall*, gpointer);
  static void BusCall(GDBusConnection*, const char*, const char*, const char*,
                      const char*, GVariant*, GDBusMethodInvocation*, gpointer);
  static GVariant* GetProperty(GDBusConnection*, const char*, const char*,
                               const char*, const char*, GError**, gpointer);
  static gboolean SetProperty(GDBusConnection*, const char*, const char*,
                               const char*, const char*, GVariant*, GError**, gpointer);
  void Update(FlValue* args);
  void Changed();
  GVariant* Metadata() const;
  gint64 Position() const;
  void Invoke(const char* method, FlValue* args, GDBusMethodInvocation* reply = nullptr,
              gint64 seek_position = -1);
  FlMethodChannel* channel_ = nullptr;
  GDBusConnection* bus_ = nullptr;
  GDBusNodeInfo* node_ = nullptr;
  guint owner_ = 0;
  guint root_registration_ = 0;
  guint player_registration_ = 0;
  std::function<void()> raise_, quit_;
  std::string track_ = "/org/mpris/MediaPlayer2/TrackList/NoTrack";
  std::string title_, artist_, album_, cover_, loop_ = "None";
  bool opened_ = false, playing_ = false, previous_ = false, next_ = false, shuffle_ = false;
  gint64 duration_ = 0, position_ = 0, updated_at_ = 0;
  double volume_ = 1;
};

#endif
