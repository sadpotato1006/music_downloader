#include "bluetooth_audio_monitor.h"

#include <bluetoothapis.h>
#include <functiondiscoverykeys_devpkey.h>
#include <propsys.h>
#include <propvarutil.h>

#include <algorithm>
#include <cwctype>
#include <utility>

namespace {

std::wstring Lowercase(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(),
                 [](wchar_t character) {
                   return static_cast<wchar_t>(std::towlower(character));
                 });
  return value;
}

std::wstring EndpointFriendlyName(IMMDevice* device) {
  IPropertyStore* properties = nullptr;
  if (!device ||
      FAILED(device->OpenPropertyStore(STGM_READ, &properties))) {
    return L"";
  }

  PROPVARIANT value;
  PropVariantInit(&value);
  std::wstring name;
  if (SUCCEEDED(properties->GetValue(PKEY_Device_FriendlyName, &value))) {
    if (value.vt == VT_LPWSTR && value.pwszVal) {
      name = value.pwszVal;
    } else if (value.vt == VT_BSTR && value.bstrVal) {
      name = value.bstrVal;
    }
  }
  PropVariantClear(&value);
  properties->Release();
  return name;
}

bool MatchesConnectedBluetoothDevice(const std::wstring& endpoint_name) {
  if (endpoint_name.empty()) {
    return false;
  }
  const auto normalized_endpoint_name = Lowercase(endpoint_name);

  BLUETOOTH_DEVICE_SEARCH_PARAMS search{};
  search.dwSize = sizeof(search);
  search.fReturnAuthenticated = TRUE;
  search.fReturnRemembered = TRUE;
  search.fReturnUnknown = TRUE;
  search.fReturnConnected = TRUE;
  search.fIssueInquiry = FALSE;

  BLUETOOTH_DEVICE_INFO device{};
  device.dwSize = sizeof(device);
  HBLUETOOTH_DEVICE_FIND find =
      BluetoothFindFirstDevice(&search, &device);
  if (find) {
    do {
      if (!device.fConnected || device.szName[0] == L'\0') {
        continue;
      }
      const auto bluetooth_name = Lowercase(device.szName);
      if (bluetooth_name.size() >= 3 &&
          (normalized_endpoint_name.find(bluetooth_name) !=
               std::wstring::npos ||
           bluetooth_name.find(normalized_endpoint_name) !=
               std::wstring::npos)) {
        BluetoothFindDeviceClose(find);
        return true;
      }
    } while (BluetoothFindNextDevice(find, &device));
    BluetoothFindDeviceClose(find);
  }

  return normalized_endpoint_name.find(L"bluetooth") !=
             std::wstring::npos ||
         normalized_endpoint_name.find(L"\u84DD\u7259") !=
             std::wstring::npos;
}

}  // namespace

BluetoothAudioMonitor::BluetoothAudioMonitor(
    HWND window,
    RouteLostOrSwitchedCallback callback)
    : window_(window), callback_(std::move(callback)) {}

BluetoothAudioMonitor::~BluetoothAudioMonitor() {
  Stop();
}

bool BluetoothAudioMonitor::Start() {
  if (enumerator_) {
    return true;
  }
  if (FAILED(CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr,
                              CLSCTX_INPROC_SERVER,
                              IID_PPV_ARGS(&enumerator_)))) {
    return false;
  }
  if (FAILED(enumerator_->RegisterEndpointNotificationCallback(this))) {
    enumerator_->Release();
    enumerator_ = nullptr;
    return false;
  }
  registered_ = true;
  Refresh();
  return true;
}

void BluetoothAudioMonitor::Stop() {
  if (!enumerator_) {
    return;
  }
  if (registered_) {
    enumerator_->UnregisterEndpointNotificationCallback(this);
    registered_ = false;
  }
  enumerator_->Release();
  enumerator_ = nullptr;
}

void BluetoothAudioMonitor::Refresh() {
  std::wstring next_device_id;
  bool next_is_bluetooth = false;
  ReadDefaultAudioRoute(&next_device_id, &next_is_bluetooth);

  const bool should_pause =
      initialized_ && active_device_is_bluetooth_ &&
      (!next_is_bluetooth || next_device_id != active_device_id_);
  active_device_id_ = std::move(next_device_id);
  active_device_is_bluetooth_ = next_is_bluetooth;
  initialized_ = true;

  if (should_pause && callback_) {
    callback_();
  }
}

HRESULT BluetoothAudioMonitor::QueryInterface(REFIID interface_id,
                                               void** object) {
  if (!object) {
    return E_POINTER;
  }
  *object = nullptr;
  if (interface_id == __uuidof(IUnknown) ||
      interface_id == __uuidof(IMMNotificationClient)) {
    *object = static_cast<IMMNotificationClient*>(this);
    AddRef();
    return S_OK;
  }
  return E_NOINTERFACE;
}

ULONG BluetoothAudioMonitor::AddRef() {
  return ++reference_count_;
}

ULONG BluetoothAudioMonitor::Release() {
  const ULONG remaining = --reference_count_;
  if (remaining == 0) {
    delete this;
  }
  return remaining;
}

HRESULT BluetoothAudioMonitor::OnDefaultDeviceChanged(
    EDataFlow flow,
    ERole role,
    LPCWSTR default_device_id) {
  if (flow == eRender) {
    RequestRefresh();
  }
  return S_OK;
}

HRESULT BluetoothAudioMonitor::OnDeviceAdded(LPCWSTR device_id) {
  RequestRefresh();
  return S_OK;
}

HRESULT BluetoothAudioMonitor::OnDeviceRemoved(LPCWSTR device_id) {
  RequestRefresh();
  return S_OK;
}

HRESULT BluetoothAudioMonitor::OnDeviceStateChanged(LPCWSTR device_id,
                                                     DWORD new_state) {
  RequestRefresh();
  return S_OK;
}

HRESULT BluetoothAudioMonitor::OnPropertyValueChanged(
    LPCWSTR device_id,
    const PROPERTYKEY key) {
  RequestRefresh();
  return S_OK;
}

void BluetoothAudioMonitor::RequestRefresh() {
  if (window_) {
    PostMessage(window_, kBluetoothAudioRouteChangedMessage, 0, 0);
  }
}

bool BluetoothAudioMonitor::ReadDefaultAudioRoute(
    std::wstring* device_id,
    bool* is_bluetooth) {
  if (!enumerator_ || !device_id || !is_bluetooth) {
    return false;
  }
  device_id->clear();
  *is_bluetooth = false;

  IMMDevice* device = nullptr;
  HRESULT result =
      enumerator_->GetDefaultAudioEndpoint(eRender, eMultimedia, &device);
  if (FAILED(result)) {
    result = enumerator_->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  }
  if (FAILED(result) || !device) {
    return false;
  }

  LPWSTR raw_device_id = nullptr;
  if (SUCCEEDED(device->GetId(&raw_device_id)) && raw_device_id) {
    *device_id = raw_device_id;
    CoTaskMemFree(raw_device_id);
  }
  *is_bluetooth = IsBluetoothEndpoint(device);
  device->Release();
  return !device_id->empty();
}

bool BluetoothAudioMonitor::IsBluetoothEndpoint(IMMDevice* device) {
  return MatchesConnectedBluetoothDevice(EndpointFriendlyName(device));
}
