import React, { useState, useEffect } from 'react';
import { Routes, Route, useNavigate, useLocation } from 'react-router-dom';
import { Layout, Menu, Modal, Input, Form, message, Button, ConfigProvider, Breadcrumb } from 'antd';
import {
  PlusCircleOutlined,
  DashboardOutlined,
  HistoryOutlined,
  SettingOutlined,
  LogoutOutlined,
  CloudServerOutlined,
} from '@ant-design/icons';
import { setCredentials, getCredentials, clearCredentials, getStatus } from './api/client';
import BookingPage from './pages/BookingPage';
import MonitoringPage from './pages/MonitoringPage';
import HistoryPage from './pages/HistoryPage';
import SettingsPage from './pages/SettingsPage';

const { Header, Content } = Layout;

const AWS_THEME = {
  token: {
    colorPrimary: '#ff9900',
    colorLink: '#ff9900',
    colorLinkHover: '#ec7211',
    borderRadius: 4,
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif',
  },
};

const NAV_ITEMS = [
  { key: '/', label: '创建预约', icon: <PlusCircleOutlined /> },
  { key: '/monitoring', label: '实时监控', icon: <DashboardOutlined /> },
  { key: '/history', label: '历史记录', icon: <HistoryOutlined /> },
  { key: '/settings', label: '通知设置', icon: <SettingOutlined /> },
];

const BREADCRUMB_MAP: Record<string, string> = {
  '/': '创建预约',
  '/monitoring': '实时监控',
  '/history': '历史记录',
  '/settings': '通知设置',
};

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

      // Verify credentials by calling backend
      try {
        await getStatus();
        setIsLoggedIn(true);
        setLoginVisible(false);
        message.success('登录成功');
      } catch {
        clearCredentials();
        message.error('用户名或密码错误');
      }
    } catch {
      // form validation failed
    }
  };

  const handleLogout = () => {
    clearCredentials();
    setIsLoggedIn(false);
    setLoginVisible(true);
    form.resetFields();
  };

  return (
    <ConfigProvider theme={AWS_THEME}>
      <Layout style={{ minHeight: '100vh', background: '#f1f3f3' }}>
        <Modal
          title="登录 GPU Cloud Console"
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
            {/* AWS-style top navigation bar */}
            <Header
              style={{
                background: '#232f3e',
                padding: '0 24px',
                display: 'flex',
                alignItems: 'center',
                height: 48,
                lineHeight: '48px',
                position: 'sticky',
                top: 0,
                zIndex: 100,
                boxShadow: '0 1px 2px rgba(0,0,0,0.2)',
              }}
            >
              {/* Brand logo area */}
              <div
                style={{
                  display: 'flex',
                  alignItems: 'center',
                  marginRight: 32,
                  cursor: 'pointer',
                }}
                onClick={() => navigate('/')}
              >
                <CloudServerOutlined
                  style={{ color: '#ff9900', fontSize: 20, marginRight: 8 }}
                />
                <span
                  style={{
                    color: '#ffffff',
                    fontSize: 16,
                    fontWeight: 600,
                    letterSpacing: '-0.2px',
                  }}
                >
                  GPU Cloud Console
                </span>
              </div>

              {/* Navigation menu */}
              <Menu
                mode="horizontal"
                selectedKeys={[location.pathname]}
                items={NAV_ITEMS}
                onClick={({ key }) => navigate(key)}
                style={{
                  background: 'transparent',
                  borderBottom: 'none',
                  flex: 1,
                  minWidth: 0,
                }}
                theme="dark"
              />

              {/* Logout button */}
              <Button
                type="text"
                icon={<LogoutOutlined />}
                onClick={handleLogout}
                style={{ color: '#aab7b8', marginLeft: 8 }}
              >
                退出
              </Button>
            </Header>

            {/* Secondary bar with service name */}
            <div
              style={{
                background: '#37475a',
                padding: '6px 24px',
                borderBottom: '1px solid #2a3f54',
              }}
            >
              <span style={{ color: '#d5dbdb', fontSize: 14, fontWeight: 500 }}>
                GPU 预约管理
              </span>
            </div>

            {/* Breadcrumb */}
            <div
              style={{
                padding: '12px 24px 0',
                background: '#f1f3f3',
              }}
            >
              <Breadcrumb
                items={[
                  { title: 'GPU Cloud Console' },
                  { title: BREADCRUMB_MAP[location.pathname] || '' },
                ]}
              />
            </div>

            {/* Content area */}
            <Content
              style={{
                margin: '16px 24px 24px',
                padding: 24,
                background: '#ffffff',
                borderRadius: 8,
                border: '1px solid #eaeded',
                boxShadow: '0 1px 1px 0 rgba(0,28,36,0.04)',
              }}
            >
              <Routes>
                <Route path="/" element={<BookingPage />} />
                <Route path="/monitoring" element={<MonitoringPage />} />
                <Route path="/history" element={<HistoryPage />} />
                <Route path="/settings" element={<SettingsPage />} />
              </Routes>
            </Content>
          </>
        )}
      </Layout>
    </ConfigProvider>
  );
};

export default App;
