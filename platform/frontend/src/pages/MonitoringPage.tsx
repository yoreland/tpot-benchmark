import React, { useState, useEffect, useCallback, useRef } from 'react';
import {
  Card,
  Tag,
  Typography,
  Space,
  Button,
  Input,
  message,
  List,
  Tooltip,
  Popconfirm,
} from 'antd';
import {
  CopyOutlined,
  ReloadOutlined,
  DeleteOutlined,
  SyncOutlined,
} from '@ant-design/icons';
import { listBookings, updateBooking, cancelBooking } from '../api/client';
import type { Booking, BookingStatus } from '../types';

const { Title, Text } = Typography;
const { TextArea } = Input;

const STATUS_CONFIG: Record<BookingStatus, { color: string; label: string }> = {
  pending: { color: 'default', label: '等待中' },
  polling: { color: 'processing', label: '寻找资源' },
  launching: { color: 'blue', label: '启动中' },
  deploying: { color: 'orange', label: '部署中' },
  ready: { color: 'success', label: '就绪' },
  failed: { color: 'error', label: '失败' },
  terminated: { color: 'default', label: '已终止' },
};

const MonitoringPage: React.FC = () => {
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [loading, setLoading] = useState(false);
  const [whitelistMap, setWhitelistMap] = useState<Record<string, string>>({});
  const whitelistMapRef = useRef<Record<string, string>>({});

  const updateWhitelistMap = (updater: Record<string, string> | ((prev: Record<string, string>) => Record<string, string>)) => {
    setWhitelistMap((prev) => {
      const next = typeof updater === 'function' ? updater(prev) : updater;
      whitelistMapRef.current = next;
      return next;
    });
  };

  const loadBookings = useCallback(async () => {
    setLoading(true);
    try {
      const all = await listBookings();
      const active = all.filter(
        (b) => !['terminated', 'failed'].includes(b.status),
      );
      setBookings(active);
      // Initialize whitelist text areas
      const currentMap = whitelistMapRef.current;
      const map: Record<string, string> = {};
      for (const b of active) {
        if (!(b.bookingId in currentMap)) {
          map[b.bookingId] = (b.whitelistIps || []).join('\n');
        } else {
          map[b.bookingId] = currentMap[b.bookingId];
        }
      }
      updateWhitelistMap(map);
    } catch (err) {
      message.error('获取预约列表失败');
      console.error(err);
    } finally {
      setLoading(false);
    }
  }, []);

  useEffect(() => {
    loadBookings();
    const interval = setInterval(loadBookings, 10000);
    return () => clearInterval(interval);
  }, [loadBookings]);

  const handleCopyEndpoint = (endpoint: string) => {
    navigator.clipboard.writeText(endpoint);
    message.success('已复制到剪贴板');
  };

  const handleSaveWhitelist = async (bookingId: string) => {
    const text = whitelistMapRef.current[bookingId] || '';
    const ips = text
      .split('\n')
      .map((ip) => ip.trim())
      .filter((ip) => ip.length > 0);
    try {
      await updateBooking(bookingId, { whitelistIps: ips });
      message.success('白名单已更新');
    } catch (err) {
      message.error('更新白名单失败');
      console.error(err);
    }
  };

  const handleCancel = async (bookingId: string) => {
    try {
      await cancelBooking(bookingId);
      message.success('已取消预约');
      loadBookings();
    } catch (err) {
      message.error('取消预约失败');
      console.error(err);
    }
  };

  const renderBookingCard = (booking: Booking) => {
    const statusConf = STATUS_CONFIG[booking.status];
    const endpoint = booking.status === 'ready' && booking.publicIp
      ? `http://${booking.publicIp}:30080/v1`
      : booking.endpoint;

    return (
      <List.Item key={booking.bookingId}>
        <Card
          style={{ width: '100%' }}
          title={
            <Space>
              <Text strong>{booking.deploymentPlanName}</Text>
              <Tag
                color={statusConf.color}
                icon={
                  ['polling', 'launching', 'deploying'].includes(booking.status)
                    ? <SyncOutlined spin />
                    : undefined
                }
              >
                {statusConf.label}
              </Tag>
            </Space>
          }
          extra={
            <Popconfirm
              title="确认取消该预约？"
              onConfirm={() => handleCancel(booking.bookingId)}
              okText="确认"
              cancelText="取消"
            >
              <Button danger icon={<DeleteOutlined />} size="small">
                终止
              </Button>
            </Popconfirm>
          }
        >
          <Space direction="vertical" style={{ width: '100%' }}>
            <Text type="secondary">
              机型: {booking.instanceType} | 区域: {booking.region || '-'} | AZ: {booking.az || '-'}
            </Text>

            {booking.status === 'ready' && endpoint && (
              <Card size="small" title="OpenAI 兼容 Endpoint">
                <Space>
                  <Text code copyable={false}>{endpoint}</Text>
                  <Tooltip title="复制">
                    <Button
                      icon={<CopyOutlined />}
                      size="small"
                      onClick={() => handleCopyEndpoint(endpoint)}
                    />
                  </Tooltip>
                </Space>
              </Card>
            )}

            {booking.status === 'ready' && (
              <Card size="small" title="IP 白名单">
                <TextArea
                  rows={3}
                  placeholder="每行一个IP地址，例如：&#10;10.0.0.1/32&#10;192.168.1.0/24"
                  value={whitelistMap[booking.bookingId] || ''}
                  onChange={(e) =>
                    updateWhitelistMap((prev) => ({
                      ...prev,
                      [booking.bookingId]: e.target.value,
                    }))
                  }
                />
                <Button
                  type="primary"
                  size="small"
                  style={{ marginTop: 8 }}
                  onClick={() => handleSaveWhitelist(booking.bookingId)}
                >
                  保存白名单
                </Button>
              </Card>
            )}
          </Space>
        </Card>
      </List.Item>
    );
  };

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Title level={3} style={{ margin: 0 }}>实时监控</Title>
        <Button
          icon={<ReloadOutlined />}
          loading={loading}
          onClick={loadBookings}
        >
          刷新
        </Button>
        <Text type="secondary">每10秒自动刷新</Text>
      </Space>

      {bookings.length === 0 ? (
        <Card>
          <Text type="secondary">暂无活跃预约</Text>
        </Card>
      ) : (
        <List
          dataSource={bookings}
          renderItem={renderBookingCard}
          split={false}
        />
      )}
    </div>
  );
};

export default MonitoringPage;
