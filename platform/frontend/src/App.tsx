import React, { useState, useEffect } from 'react';
import { Routes, Route, useNavigate, useLocation } from 'react-router-dom';
import { Layout, Menu, Modal, Input, Form, message, Button } from 'antd';
import {
  PlusCircleOutlined,
  DashboardOutlined,
  HistoryOutlined,
  SettingOutlined,
  LogoutOutlined,
} from '@ant-design/icons';
import { setCredentials, getCredentials, clearCredentials } from './api/client';
import BookingPage from './pages/BookingPage';
import MonitoringPage from './pages/MonitoringPage';
import HistoryPage from './pages/HistoryPage';
import SettingsPage from './pages/SettingsPage';

const { Header, Sider, Content } = Layout;

const App: React.FC = () => {
  const [isLoggedIn, setIsLoggedIn] = useState(false);
  const [loginVisible, setLoginVisible] = useState(false);
  const [form] = Form.useForm();
  const navigate = useNavigate();
  const location = useLocation();

  useEffect(() => {
    const creds = getCredentials();
    if (creds) {
      setIsLoggedIn(true);
    } else {
      setLoginVisible(true);
    }
  }, []);

  const handleLogin = async () => {
    try {
      const values = await form.validateFields();
      setCredentials(values.username, values.password);
      setIsLoggedIn(true);
      setLoginVisible(false);
      message.success('登录成功');
    } catch {
      // validation failed
    }
  };

  const handleLogout = () => {
    clearCredentials();
    setIsLoggedIn(false);
    setLoginVisible(true);
    form.resetFields();
  };

  const menuItems = [
    {
      key: '/',
      icon: <PlusCircleOutlined />,
      label: '创建预约',
    },
    {
      key: '/monitoring',
      icon: <DashboardOutlined />,
      label: '实时监控',
    },
    {
      key: '/history',
      icon: <HistoryOutlined />,
      label: '历史记录',
    },
    {
      key: '/settings',
      icon: <SettingOutlined />,
      label: '通知设置',
    },
  ];

  return (
    <Layout style={{ minHeight: '100vh' }}>
      <Modal
        title="登录 T-POT GPU Booking"
        open={loginVisible}
        onOk={handleLogin}
        closable={false}
        maskClosable={false}
        okText="登录"
        cancelButtonProps={{ style: { display: 'none' } }}
      >
        <Form form={form} layout="vertical">
          <Form.Item
            name="username"
            label="用户名"
            rules={[{ required: true, message: '请输入用户名' }]}
          >
            <Input />
          </Form.Item>
          <Form.Item
            name="password"
            label="密码"
            rules={[{ required: true, message: '请输入密码' }]}
          >
            <Input.Password onPressEnter={handleLogin} />
          </Form.Item>
        </Form>
      </Modal>

      {isLoggedIn && (
        <>
          <Sider theme="dark" breakpoint="lg" collapsedWidth="0">
            <div
              style={{
                height: 32,
                margin: 16,
                color: '#fff',
                fontSize: 16,
                fontWeight: 'bold',
                textAlign: 'center',
              }}
            >
              T-POT Booking
            </div>
            <Menu
              theme="dark"
              mode="inline"
              selectedKeys={[location.pathname]}
              items={menuItems}
              onClick={({ key }) => navigate(key)}
            />
            <div style={{ position: 'absolute', bottom: 16, left: 16 }}>
              <Button
                type="text"
                icon={<LogoutOutlined />}
                onClick={handleLogout}
                style={{ color: '#fff' }}
              >
                退出
              </Button>
            </div>
          </Sider>
          <Layout>
            <Header
              style={{
                background: '#fff',
                padding: '0 24px',
                fontSize: 18,
                fontWeight: 'bold',
              }}
            >
              GPU 一键预约平台
            </Header>
            <Content style={{ margin: '24px 16px', padding: 24, background: '#fff' }}>
              <Routes>
                <Route path="/" element={<BookingPage />} />
                <Route path="/monitoring" element={<MonitoringPage />} />
                <Route path="/history" element={<HistoryPage />} />
                <Route path="/settings" element={<SettingsPage />} />
              </Routes>
            </Content>
          </Layout>
        </>
      )}
    </Layout>
  );
};

export default App;
