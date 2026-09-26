import { Logger } from '../common/Logger';
import { DiscoveredDeviceInfo, DeviceDiscovery, DeviceDiscoveryCallback } from './DeviceDiscovery';

const TAG_MODULE = 'DeviceStateMonitor';

export interface DeviceStateCallback {
  onDeviceJoined: (device: DiscoveredDeviceInfo) => void;
  onDeviceLeft: (deviceId: string) => void;
  onRoleChanged: (deviceId: string, newRole: string) => void;
  onNetworkChanged: (online: boolean) => void;
}

export class DeviceStateMonitor {
  private callbacks: DeviceStateCallback[] = [];
  private discovery: DeviceDiscovery;

  constructor() {
    this.discovery = DeviceDiscovery.getInstance();
    this.discovery.registerCallback({
      onDeviceFound: (device) => {
        this.callbacks.forEach(cb => cb.onDeviceJoined(device));
      },
      onDeviceLost: (deviceId) => {
        this.callbacks.forEach(cb => cb.onDeviceLeft(deviceId));
      },
      onBindSuccess: (device) => {
        Logger.info(TAG_MODULE, `Device bound: ${device.deviceName}`);
      },
      onBindFailed: (deviceId, error) => {
        Logger.error(TAG_MODULE, `Bind failed: ${deviceId} - ${error}`);
      },
      onDiscoveryComplete: (devices) => {
        Logger.info(TAG_MODULE, `Discovery complete: ${devices.length} devices`);
      },
      onDeviceOnline: (deviceId) => {
        Logger.info(TAG_MODULE, `Device online: ${deviceId}`);
      },
      onDeviceOffline: (deviceId) => {
        this.callbacks.forEach(cb => cb.onDeviceLeft(deviceId));
        Logger.info(TAG_MODULE, `Device offline: ${deviceId}`);
      }
    });
  }

  registerCallback(cb: DeviceStateCallback): void { this.callbacks.push(cb); }
  unregisterCallback(cb: DeviceStateCallback): void {
    const idx = this.callbacks.indexOf(cb);
    if (idx >= 0) this.callbacks.splice(idx, 1);
  }

  getConnectedDevices(): DiscoveredDeviceInfo[] {
    return this.discovery.getBoundDevices();
  }
}
