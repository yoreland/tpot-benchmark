import React, { useState, useEffect } from 'react';
import { Table, Tag, Select, Typography, Space, message } from 'antd';
import type { ColumnsType } from 'antd/es/table';
import { listBookings } from '../api/client';
import type { Booking, BookingStatus } from '../types';

const { Title } = Typography;

const STATUS_CONFIG: Record<BookingStatus, { color: string; label: string }> = {
  pending: { color: 'default', label: '等待中' },
  polling: { color: 'processing', label: '寻找资源' },
  launching: { color: 'blue', label: '启动中' },
  deploying: { color: 'orange', label: '部署中' },
  ready: { color: 'success', label: '就绪' },
  failed: { color: 'error', label: '失败' },
  terminated: { color: 'default', label: '已终止' },
};

const HistoryPage: React.FC = () => {
  const [bookings, setBookings] = useState<Booking[]>([]);
  const [loading, setLoading] = useState(false);
  const [statusFilter, setStatusFilter] = useState<string | undefined>();

  useEffect(() => {
    loadBookings();
  }, [statusFilter]);

  const loadBookings = async () => {
    setLoading(true);
    try {
      const data = await listBookings(statusFilter);
      // Sort by createdAt desc
      data.sort((a, b) =>
        new Date(b.createdAt).getTime() - new Date(a.createdAt).getTime(),
      );
      setBookings(data);
    } catch (err) {
      message.error('获取历史记录失败');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const columns: ColumnsType<Booking> = [
    {
      title: '预约ID',
      dataIndex: 'bookingId',
      key: 'bookingId',
      width: 120,
      ellipsis: true,
    },
    {
      title: '机型',
      dataIndex: 'instanceType',
      key: 'instanceType',
    },
    {
      title: '部署方案',
      dataIndex: 'deploymentPlanName',
      key: 'deploymentPlanName',
    },
    {
      title: '状态',
      dataIndex: 'status',
      key: 'status',
      render: (status: BookingStatus) => {
        const conf = STATUS_CONFIG[status];
        return <Tag color={conf.color}>{conf.label}</Tag>;
      },
    },
    {
      title: '创建时间',
      dataIndex: 'createdAt',
      key: 'createdAt',
      render: (val: string) => val ? new Date(val).toLocaleString('zh-CN') : '-',
    },
    {
      title: '区域',
      dataIndex: 'region',
      key: 'region',
      render: (val: string) => val || '-',
    },
    {
      title: '实例ID',
      dataIndex: 'instanceId',
      key: 'instanceId',
      ellipsis: true,
      render: (val: string) => val || '-',
    },
  ];

  return (
    <div>
      <Space style={{ marginBottom: 16 }}>
        <Title level={3} style={{ margin: 0 }}>历史记录</Title>
        <Select
          style={{ width: 160 }}
          placeholder="筛选状态"
          allowClear
          value={statusFilter}
          onChange={setStatusFilter}
          options={[
            { value: 'pending', label: '等待中' },
            { value: 'polling', label: '寻找资源' },
            { value: 'launching', label: '启动中' },
            { value: 'deploying', label: '部署中' },
            { value: 'ready', label: '就绪' },
            { value: 'failed', label: '失败' },
            { value: 'terminated', label: '已终止' },
          ]}
        />
      </Space>

      <Table
        columns={columns}
        dataSource={bookings}
        rowKey="bookingId"
        loading={loading}
        pagination={{ pageSize: 20 }}
      />
    </div>
  );
};

export default HistoryPage;
