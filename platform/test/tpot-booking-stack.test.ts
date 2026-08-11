import * as cdk from 'aws-cdk-lib';
import { Template } from 'aws-cdk-lib/assertions';
import { TpotBookingStack } from '../lib/tpot-booking-stack';

describe('TpotBookingStack', () => {
  let template: Template;

  beforeAll(() => {
    const app = new cdk.App();
    const stack = new TpotBookingStack(app, 'TestStack', {
      env: { account: '077090643075', region: 'us-east-1' },
    });
    template = Template.fromStack(stack);
  });

  test('synthesizes without error', () => {
    expect(template).toBeDefined();
  });

  test('creates BookingTable with GSI', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'TpotBookingTable',
      KeySchema: [{ AttributeName: 'bookingId', KeyType: 'HASH' }],
      GlobalSecondaryIndexes: [
        {
          IndexName: 'instanceType-status-index',
          KeySchema: [
            { AttributeName: 'instanceType', KeyType: 'HASH' },
            { AttributeName: 'status', KeyType: 'RANGE' },
          ],
        },
      ],
    });
  });

  test('creates NotificationConfigTable', () => {
    template.hasResourceProperties('AWS::DynamoDB::Table', {
      TableName: 'TpotNotificationConfigTable',
      KeySchema: [{ AttributeName: 'configId', KeyType: 'HASH' }],
    });
  });

  test('creates API Gateway REST API', () => {
    template.hasResourceProperties('AWS::ApiGateway::RestApi', {
      Name: 'TpotBookingApi',
    });
  });

  test('creates Lambda authorizer function', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'tpot-booking-authorizer',
      Runtime: 'python3.12',
    });
  });

  test('creates API handler Lambda', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'tpot-booking-api-handler',
      Runtime: 'python3.12',
    });
  });

  test('creates capacity poller Lambda', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'tpot-booking-capacity-poller',
      Runtime: 'python3.12',
    });
  });

  test('creates deployer Lambda', () => {
    template.hasResourceProperties('AWS::Lambda::Function', {
      FunctionName: 'tpot-booking-deployer',
      Runtime: 'python3.12',
    });
  });

  test('creates S3 bucket for frontend', () => {
    template.hasResourceProperties('AWS::S3::Bucket', {
      BucketName: 'tpot-booking-frontend-077090643075',
    });
  });

  test('creates CloudFront distribution', () => {
    template.hasResourceProperties('AWS::CloudFront::Distribution', {
      DistributionConfig: {
        DefaultRootObject: 'index.html',
      },
    });
  });

  test('creates SNS topic', () => {
    template.hasResourceProperties('AWS::SNS::Topic', {
      TopicName: 'TpotBookingNotifications',
    });
  });

  test('has expected outputs', () => {
    template.hasOutput('ApiUrl', {});
    template.hasOutput('CloudFrontDomain', {});
    template.hasOutput('BookingTableName', {});
    template.hasOutput('NotificationConfigTableName', {});
    template.hasOutput('NotificationTopicArn', {});
    template.hasOutput('FrontendBucketName', {});
  });

  test('creates EventBridge schedule rule for capacity poller', () => {
    template.hasResourceProperties('AWS::Events::Rule', {
      Name: 'tpot-booking-capacity-poller-schedule',
      ScheduleExpression: 'rate(1 minute)',
    });
  });

  test('creates EventBridge rule for EC2 state changes', () => {
    template.hasResourceProperties('AWS::Events::Rule', {
      Name: 'tpot-booking-deployer-ec2-state-change',
      EventPattern: {
        source: ['aws.ec2'],
        'detail-type': ['EC2 Instance State-change Notification'],
        detail: { state: ['running'] },
      },
    });
  });

  test('creates EC2 instance profile for SSM', () => {
    template.hasResourceProperties('AWS::IAM::InstanceProfile', {
      InstanceProfileName: 'tpot-bench-ec2-profile',
    });
  });
});
