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
  source?: 'builtin' | 'user';
  modelName?: string;
  composeFile?: string;
}

export interface CreateDeploymentPlanRequest {
  name: string;
  instanceType: string;
  composeContent: string;
  modelName?: string;
  description?: string;
  recipe?: string;
  overwrite?: boolean;
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
