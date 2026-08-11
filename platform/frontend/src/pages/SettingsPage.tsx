import React, { useState, useEffect } from 'react';
import { Card, Input, Button, Form, message, Typography, Space } from 'antd';
import { MailOutlined, LinkOutlined } from '@ant-design/icons';
import { getNotificationConfig, updateNotificationConfig } from '../api/client';

const { Title, Text } = Typography;

const SettingsPage: React.FC = () => {
  const [form] = Form.useForm();
  const [loading, setLoading] = useState(false);
  const [testingWebhook, setTestingWebhook] = useState(false);

  useEffect(() => {
    loadConfig();
  }, []);

  const loadConfig = async () => {
    try {
      const config = await getNotificationConfig();
      form.setFieldsValue({
        email: config.email || '',
        feishuWebhook: config.feishuWebhook || '',
      });
    } catch (err) {
      console.error('获取通知配置失败:', err);
    }
  };

  const handleSave = async () => {
    setLoading(true);
    try {
      const values = await form.validateFields();
      await updateNotificationConfig({
        email: values.email || undefined,
        feishuWebhook: values.feishuWebhook || undefined,
      });
      message.success('通知设置已保存');
    } catch (err) {
      message.error('保存失败');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const handleTestWebhook = async () => {
    const webhook = form.getFieldValue('feishuWebhook');
    if (!webhook) {
      message.warning('请先输入飞书 Webhook 地址');
      return;
    }
    setTestingWebhook(true);
    try {
      await fetch(webhook, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({
          msg_type: 'text',
          content: {
            text: '[T-POT Booking] 测试通知 - Webhook 配置成功!',
          },
        }),
      });
      message.success('测试消息已发送，请检查飞书');
    } catch (err) {
      message.error('发送测试消息失败');
      console.error(err);
    } finally {
      setTestingWebhook(false);
    }
  };

  return (
    <div>
      <Title level={3}>通知设置</Title>
      <Card style={{ maxWidth: 600 }}>
        <Form form={form} layout="vertical">
          <Form.Item
            name="email"
            label={
              <Space>
                <MailOutlined />
                <Text>邮件通知</Text>
              </Space>
            }
            help="预约状态变更时发送邮件通知"
          >
            <Input placeholder="your-email@example.com" type="email" />
          </Form.Item>

          <Form.Item
            name="feishuWebhook"
            label={
              <Space>
                <LinkOutlined />
                <Text>飞书机器人 Webhook</Text>
              </Space>
            }
            help="配置飞书群机器人的 Webhook URL，状态变更时推送通知"
          >
            <Input placeholder="https://open.feishu.cn/open-apis/bot/v2/hook/xxxxx" />
          </Form.Item>

          <Form.Item>
            <Space>
              <Button type="primary" loading={loading} onClick={handleSave}>
                保存设置
              </Button>
              <Button loading={testingWebhook} onClick={handleTestWebhook}>
                测试飞书 Webhook
              </Button>
            </Space>
          </Form.Item>
        </Form>
      </Card>
    </div>
  );
};

export default SettingsPage;
