export interface Booking {
  bookingId: string;
  instanceType: string;
  deploymentPlanId: string;
  deploymentPlanName: string;
  status: BookingStatus;
  endpoint?: string;
  whitelistIps: string[];
  createdAt: string;
  updatedAt: string;
  instanceId?: string;
  region?: string;
  az?: string;
  publicIp?: string;
}

export type BookingStatus =
  | 'pending'
  | 'polling'
  | 'launching'
  | 'deploying'
  | 'ready'
  | 'failed'
  | 'terminated';

export interface DeploymentPlan {
  id: string;
  name: string;
  instanceType: string;
  description: string;
}

export interface NotificationConfig {
  feishuWebhook?: string;
}

export interface ConflictResponse {
  error: string;
  message: string;
  conflicting: Booking[];
}

export interface StatusResponse {
  deploymentPlans: DeploymentPlan[];
  runningInstances: Booking[];
}
