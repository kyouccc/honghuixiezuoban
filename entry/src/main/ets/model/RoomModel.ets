export interface RoomModel {
  roomId: string;
  name: string;
  joinCode: string;
  wsEndpoint: string;
  participants: number;
  maxParticipants: number;
  createdAt: string;
  expiresAt: string;
  hostDeviceId: string;
}
