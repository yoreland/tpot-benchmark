import React, { useState, useEffect } from 'react';
import {
  Card,
  Input,
  Select,
  Button,
  Form,
  Upload,
  Table,
  Tag,
  Popconfirm,
  message,
  Typography,
  Space,
} from 'antd';
import type { UploadFile } from 'antd';
import { CloudUploadOutlined, InboxOutlined } from '@ant-design/icons';
import type { ColumnsType } from 'antd/es/table';
import {
  createDeploymentPlan,
  listDeploymentPlans,
  deleteDeploymentPlan,
} from '../api/client';
import type { DeploymentPlan } from '../types';

const { Title, Text } = Typography;

const INSTANCE_TYPE_OPTIONS = [
  { value: 'p5en.48xlarge', label: 'p5en.48xlarge' },
  { value: 'p6-b300.48xlarge', label: 'p6-b300.48xlarge' },
];

const PlansPage: React.FC = () => {
  const [form] = Form.useForm();
  const [plans, setPlans] = useState<DeploymentPlan[]>([]);
  const [loading, setLoading] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const [composeContent, setComposeContent] = useState<string>('');
  const [fileList, setFileList] = useState<UploadFile[]>([]);

  useEffect(() => {
    loadPlans();
  }, []);

  const loadPlans = async () => {
    setLoading(true);
    try {
      const data = await listDeploymentPlans();
      setPlans(data);
    } catch (err) {
      message.error('获取部署方案列表失败');
      console.error(err);
    } finally {
      setLoading(false);
    }
  };

  const beforeUpload = (file: File): boolean => {
    const isYaml =
      file.name.toLowerCase().endsWith('.yaml') ||
      file.name.toLowerCase().endsWith('.yml');
    if (!isYaml) {
      message.error('请上传 .yaml 或 .yml 文件');
      return false;
    }
    const reader = new FileReader();
    reader.onload = () => {
      setComposeContent(String(reader.result || ''));
    };
    reader.onerror = () => {
      message.error('读取文件失败');
      setComposeContent('');
    };
    reader.readAsText(file);
    setFileList([
      {
        uid: '-1',
        name: file.name,
        status: 'done',
      },
    ]);
    // Prevent antd from auto-uploading the file.
    return false;
  };

  const handleRemoveFile = () => {
    setComposeContent('');
    setFileList([]);
  };

  const handleSubmit = async () => {
    let values;
    try {
      values = await form.validateFields();
    } catch {
      return;
    }
    if (!composeContent) {
      message.warning('请上传 docker-compose 文件');
      return;
    }

    setSubmitting(true);
    try {
      await createDeploymentPlan({
        name: values.name,
        instanceType: values.instanceType,
        composeContent,
        modelName: values.modelName || undefined,
        description: values.description || undefined,
      });
      message.success('部署方案上传成功');
      form.resetFields();
      setComposeContent('');
      setFileList([]);
      await loadPlans();
    } catch (err) {
      const error = err as Error & { data?: { error?: string } };
      // The shared client throws a generic Error('Conflict') for all 409s with
      // the parsed API body on error.data. Surface the specific API message
      // (e.g. "collides with a built-in" / "already exists") when present.
      message.error(error.data?.error || error.message || '上传部署方案失败');
      console.error(err);
    } finally {
      setSubmitting(false);
    }
  };

  const handleDelete = async (planId: string) => {
    try {
      await deleteDeploymentPlan(planId);
      message.success('部署方案已删除');
      await loadPlans();
    } catch (err) {
      const error = err as Error;
      message.error(error.message || '删除部署方案失败');
      console.error(err);
    }
  };

  const columns: ColumnsType<DeploymentPlan> = [
    {
      title: '名称',
      dataIndex: 'name',
      key: 'name',
    },
    {
      title: 'ID',
      dataIndex: 'id',
      key: 'id',
      ellipsis: true,
    },
    {
      title: '机型',
      dataIndex: 'instanceType',
      key: 'instanceType',
    },
    {
      title: '来源',
      dataIndex: 'source',
      key: 'source',
      render: (source: DeploymentPlan['source']) =>
        source === 'user' ? (
          <Tag color="blue">自定义</Tag>
        ) : (
          <Tag color="default">内置</Tag>
        ),
    },
    {
      title: '操作',
      key: 'action',
      width: 120,
      render: (_, record) =>
        record.source === 'user' ? (
          <Popconfirm
            title="确认删除该部署方案？"
            okText="删除"
            cancelText="取消"
            okButtonProps={{ danger: true }}
            onConfirm={() => handleDelete(record.id)}
          >
            <Button type="link" danger>
              删除
            </Button>
          </Popconfirm>
        ) : (
          <Button type="link" disabled>
            删除
          </Button>
        ),
    },
  ];

  return (
    <div>
      <Title level={3} style={{ marginBottom: 16 }}>方案管理</Title>

      <Card
        style={{ maxWidth: 600, borderRadius: 8, marginBottom: 24 }}
        styles={{ header: { borderBottom: '2px solid #ff9900' } }}
        title="上传部署方案"
      >
        <Form form={form} layout="vertical">
          <Form.Item
            name="name"
            label="方案名称"
            rules={[{ required: true, message: '请输入方案名称' }]}
          >
            <Input placeholder="例如：DeepSeek V4 Flash" />
          </Form.Item>

          <Form.Item
            name="instanceType"
            label="机型"
            rules={[{ required: true, message: '请选择机型' }]}
          >
            <Select placeholder="请选择机型" options={INSTANCE_TYPE_OPTIONS} />
          </Form.Item>

          <Form.Item name="modelName" label="模型名称（可选）">
            <Input placeholder="deepseek-ai/DeepSeek-V4-Flash" />
          </Form.Item>

          <Form.Item name="description" label="描述（可选）">
            <Input placeholder="方案描述" />
          </Form.Item>

          <Form.Item
            label="docker-compose 文件"
            required
            help="上传 .yaml 或 .yml 格式的 docker-compose 文件"
          >
            <Upload.Dragger
              accept=".yaml,.yml"
              maxCount={1}
              fileList={fileList}
              beforeUpload={beforeUpload}
              onRemove={handleRemoveFile}
            >
              <p className="ant-upload-drag-icon">
                <InboxOutlined />
              </p>
              <p className="ant-upload-text">点击或拖拽文件到此处上传</p>
              <p className="ant-upload-hint">仅支持 .yaml / .yml 文件</p>
            </Upload.Dragger>
          </Form.Item>

          <Form.Item>
            <Space>
              <Button
                type="primary"
                icon={<CloudUploadOutlined />}
                loading={submitting}
                onClick={handleSubmit}
              >
                上传方案
              </Button>
              <Text type="secondary">
                上传后 CDK 重新部署即可生效
              </Text>
            </Space>
          </Form.Item>
        </Form>
      </Card>

      <Card style={{ borderRadius: 8 }} title="已有部署方案">
        <Table
          columns={columns}
          dataSource={plans}
          rowKey="id"
          loading={loading}
          pagination={{ pageSize: 20 }}
        />
      </Card>
    </div>
  );
};

export default PlansPage;
