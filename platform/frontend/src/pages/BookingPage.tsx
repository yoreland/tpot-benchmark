import React, { useState, useEffect } from 'react';
import { Card, Select, Button, Modal, message, Typography, Space, Descriptions } from 'antd';
import { ThunderboltOutlined } from '@ant-design/icons';
import { getStatus, createBooking } from '../api/client';
import type { DeploymentPlan, ConflictResponse } from '../types';

const { Title, Text } = Typography;

const BookingPage: React.FC = () => {
  const [plans, setPlans] = useState<DeploymentPlan[]>([]);
  const [selectedPlan, setSelectedPlan] = useState<string | undefined>();
  const [loading, setLoading] = useState(false);
  const [conflictData, setConflictData] = useState<ConflictResponse | null>(null);

  useEffect(() => {
    loadPlans();
  }, []);

  const loadPlans = async () => {
    try {
      const status = await getStatus();
      setPlans(status.deploymentPlans);
    } catch (err) {
      message.error('获取部署方案失败');
      console.error(err);
    }
  };

  const handleSubmit = async (confirmOverride?: boolean) => {
    if (!selectedPlan) {
      message.warning('请选择部署方案');
      return;
    }

    setLoading(true);
    try {
      await createBooking(selectedPlan, confirmOverride);
      message.success('预约创建成功，开始查找资源...');
      setSelectedPlan(undefined);
      setConflictData(null);
    } catch (err: unknown) {
      const error = err as Error & { data?: ConflictResponse };
      if (error.message === 'Conflict' && error.data) {
        setConflictData(error.data);
      } else {
        message.error(error.message || '创建预约失败');
      }
    } finally {
      setLoading(false);
    }
  };

  const handleConflictConfirm = () => {
    handleSubmit(true);
  };

  const handleConflictCancel = () => {
    setConflictData(null);
  };

  return (
    <div>
      <Title level={3} style={{ marginBottom: 16 }}>创建 GPU 预约</Title>
      <Card
        style={{ maxWidth: 600, borderRadius: 8 }}
        styles={{ header: { borderBottom: '2px solid #ff9900' } }}
        title="选择部署方案"
      >
        <Space direction="vertical" style={{ width: '100%' }} size="large">
          <div>
            <Text strong>选择部署方案：</Text>
            <Select
              style={{ width: '100%', marginTop: 8 }}
              placeholder="请选择部署方案"
              value={selectedPlan}
              onChange={setSelectedPlan}
              options={plans.map((plan) => ({
                value: plan.id,
                label: `${plan.name}${plan.source === 'user' ? ' (自定义)' : ''} - ${plan.instanceType} - ${plan.description}`,
              }))}
              size="large"
            />
          </div>
          <Button
            type="primary"
            size="large"
            icon={<ThunderboltOutlined />}
            loading={loading}
            onClick={() => handleSubmit()}
            block
            style={{ height: 44, fontWeight: 600 }}
          >
            一键预约
          </Button>
        </Space>
      </Card>

      <Modal
        title="机型冲突确认"
        open={!!conflictData}
        onOk={handleConflictConfirm}
        onCancel={handleConflictCancel}
        okText="确认覆盖"
        cancelText="取消"
        okButtonProps={{ danger: true }}
      >
        {conflictData && conflictData.conflicting.length > 0 && (
          <div>
            <Text type="warning" style={{ fontSize: 14 }}>
              {conflictData.message}
            </Text>
            <Descriptions
              column={1}
              style={{ marginTop: 16 }}
              bordered
              size="small"
            >
              <Descriptions.Item label="预约ID">
                {conflictData.conflicting[0].bookingId}
              </Descriptions.Item>
              <Descriptions.Item label="机型">
                {conflictData.conflicting[0].instanceType}
              </Descriptions.Item>
              <Descriptions.Item label="当前方案">
                {conflictData.conflicting[0].deploymentPlanName}
              </Descriptions.Item>
              <Descriptions.Item label="状态">
                {conflictData.conflicting[0].status}
              </Descriptions.Item>
            </Descriptions>
            {conflictData.conflicting[0].instanceId ? (
              <Text
                type="success"
                style={{ display: 'block', marginTop: 16 }}
              >
                将复用当前实例，自动切换到新部署方案（无需重新抢机器）
              </Text>
            ) : (
              <Text
                type="danger"
                style={{ display: 'block', marginTop: 16 }}
              >
                确认后将停止当前运行的实例并重新部署新方案。
              </Text>
            )}
          </div>
        )}
      </Modal>
    </div>
  );
};

export default BookingPage;
