export interface DeviceModel {
  deviceId: string;
  deviceName: string;
  deviceType: string;
  screenSize: number;
  hasTouch: boolean;
  hasPenSupport: boolean;
  role: string;
  isOnline: boolean;
  batteryLevel?: number;
}
