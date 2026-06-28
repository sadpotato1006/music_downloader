#ifndef RUNNER_BLUETOOTH_AUDIO_MONITOR_H_
#define RUNNER_BLUETOOTH_AUDIO_MONITOR_H_

#include <mmdeviceapi.h>
#include <windows.h>

#include <atomic>
#include <functional>
#include <string>

constexpr UINT kBluetoothAudioRouteChangedMessage = WM_APP + 20;

class BluetoothAudioMonitor final : public IMMNotificationClient {
 public:
  using RouteLostOrSwitchedCallback = std::function<void()>;

  BluetoothAudioMonitor(HWND window,
                        RouteLostOrSwitchedCallback callback);

  bool Start();
  void Stop();
  void Refresh();

  IFACEMETHODIMP QueryInterface(REFIID interface_id,
                                void** object) override;
  ULONG STDMETHODCALLTYPE AddRef() override;
  ULONG STDMETHODCALLTYPE Release() override;

  IFACEMETHODIMP OnDefaultDeviceChanged(
      EDataFlow flow,
      ERole role,
      LPCWSTR default_device_id) override;
  IFACEMETHODIMP OnDeviceAdded(LPCWSTR device_id) override;
  IFACEMETHODIMP OnDeviceRemoved(LPCWSTR device_id) override;
  IFACEMETHODIMP OnDeviceStateChanged(LPCWSTR device_id,
                                      DWORD new_state) override;
  IFACEMETHODIMP OnPropertyValueChanged(
      LPCWSTR device_id,
      const PROPERTYKEY key) override;

 private:
  ~BluetoothAudioMonitor();

  void RequestRefresh();
  bool ReadDefaultAudioRoute(std::wstring* device_id, bool* is_bluetooth);
  bool IsBluetoothEndpoint(IMMDevice* device);

  std::atomic<ULONG> reference_count_{1};
  HWND window_;
  RouteLostOrSwitchedCallback callback_;
  IMMDeviceEnumerator* enumerator_ = nullptr;
  bool registered_ = false;
  bool initialized_ = false;
  std::wstring active_device_id_;
  bool active_device_is_bluetooth_ = false;
};

#endif  // RUNNER_BLUETOOTH_AUDIO_MONITOR_H_
