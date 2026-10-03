#ifndef QINGTING_CHANNEL_UTILS_H
#define QINGTING_CHANNEL_UTILS_H

#include <flutter_linux/flutter_linux.h>

inline FlValue* channel_argument(FlValue* args, const char* key) {
  return args != nullptr && fl_value_get_type(args) == FL_VALUE_TYPE_MAP
             ? fl_value_lookup_string(args, key) : nullptr;
}
inline const char* channel_string(FlValue* args, const char* key) {
  FlValue* value = channel_argument(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_STRING
             ? fl_value_get_string(value) : "";
}
inline bool channel_bool(FlValue* args, const char* key, bool fallback = false) {
  FlValue* value = channel_argument(args, key);
  return value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_BOOL
             ? fl_value_get_bool(value) : fallback;
}
inline double channel_number(FlValue* args, const char* key, double fallback = 0) {
  FlValue* value = channel_argument(args, key);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_INT)
    return fl_value_get_int(value);
  if (value != nullptr && fl_value_get_type(value) == FL_VALUE_TYPE_FLOAT)
    return fl_value_get_float(value);
  return fallback;
}

#endif
