export interface UserModel {
  userId: string;
  userName: string;
  avatarUrl?: string;
  deviceRole: string;
  isOnline: boolean;
  joinedAt: number;
}
