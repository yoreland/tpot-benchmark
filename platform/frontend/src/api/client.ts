import type {
  Booking,
  ConflictResponse,
  NotificationConfig,
  StatusResponse,
} from '../types';

const BASE_URL = import.meta.env.VITE_API_URL || '';

function getAuthHeader(): string {
  const creds = sessionStorage.getItem('gpu_console_credentials');
  if (!creds) return '';
  return `Basic ${btoa(creds)}`;
}

async function request<T>(
  path: string,
  options: RequestInit = {},
): Promise<T> {
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    Authorization: getAuthHeader(),
    ...(options.headers as Record<string, string> || {}),
  };

  const response = await fetch(`${BASE_URL}${path}`, {
    ...options,
    headers,
  });

  if (response.status === 409) {
    const data = await response.json();
    const error = new Error('Conflict') as Error & { data: ConflictResponse };
    error.data = data;
    throw error;
  }

  if (!response.ok) {
    const text = await response.text();
    throw new Error(`API Error ${response.status}: ${text}`);
  }

  if (response.status === 204) {
    return undefined as unknown as T;
  }

  return response.json();
}

export function setCredentials(username: string, password: string): void {
  sessionStorage.setItem('gpu_console_credentials', `${username}:${password}`);
}

export function getCredentials(): string | null {
  return sessionStorage.getItem('gpu_console_credentials');
}

export function clearCredentials(): void {
  sessionStorage.removeItem('gpu_console_credentials');
}

export async function getStatus(): Promise<StatusResponse> {
  return request<StatusResponse>('/status');
}

export async function listBookings(status?: string): Promise<Booking[]> {
  const params = status ? `?status=${status}` : '';
  const resp = await request<{ bookings: Booking[]; count: number }>(`/bookings${params}`);
  return resp.bookings;
}

export async function getBooking(id: string): Promise<Booking> {
  return request<Booking>(`/bookings/${id}`);
}

export async function createBooking(
  deploymentPlanId: string,
  confirmOverride?: boolean,
): Promise<Booking> {
  return request<Booking>('/bookings', {
    method: 'POST',
    body: JSON.stringify({ deploymentPlan: deploymentPlanId, confirmOverride }),
  });
}

export async function updateBooking(
  id: string,
  data: { whitelistIps?: string[] },
): Promise<Booking> {
  return request<Booking>(`/bookings/${id}`, {
    method: 'PUT',
    body: JSON.stringify(data),
  });
}

export async function cancelBooking(id: string): Promise<void> {
  return request<void>(`/bookings/${id}`, {
    method: 'DELETE',
  });
}

export async function getNotificationConfig(): Promise<NotificationConfig> {
  return request<NotificationConfig>('/notifications');
}

export async function updateNotificationConfig(
  config: NotificationConfig,
): Promise<NotificationConfig> {
  return request<NotificationConfig>('/notifications', {
    method: 'PUT',
    body: JSON.stringify(config),
  });
}

export async function testFeishuWebhook(webhook: string): Promise<{ message: string }> {
  return request<{ message: string }>('/notifications/test-webhook', {
    method: 'POST',
    body: JSON.stringify({ webhook }),
  });
}
