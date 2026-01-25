export enum ConnectionState {
  DISCONNECTED = 'DISCONNECTED',
  CONNECTING = 'CONNECTING',
  CONNECTED = 'CONNECTED',
  ERROR = 'ERROR',
}

export interface LogMessage {
  id: string;
  timestamp: Date;
  sender: 'user' | 'model' | 'system';
  text: string;
  isThought?: boolean;
}

export interface VolumeData {
  input: number;
  output: number;
}
