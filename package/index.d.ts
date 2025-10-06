export interface PingOption {
  count?: number;
  interval_ms?: number;
  timeout_ms?: number;
  ip_version?: string;
}

export interface PingResult {
  sequence: number;
  rtt_ms: number;
  success: boolean;
  error_msg?: string;
  ip_addr: string;
}

export declare function ping(
  host: string,
  config?: PingOption
): Promise<PingResult[]>;
