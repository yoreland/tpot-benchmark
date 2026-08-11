import * as cdk from 'aws-cdk-lib';
import * as dynamodb from 'aws-cdk-lib/aws-dynamodb';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as apigateway from 'aws-cdk-lib/aws-apigateway';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as s3deploy from 'aws-cdk-lib/aws-s3-deployment';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as sns from 'aws-cdk-lib/aws-sns';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as ssm from 'aws-cdk-lib/aws-ssm';
import * as events from 'aws-cdk-lib/aws-events';
import * as targets from 'aws-cdk-lib/aws-events-targets';
import * as path from 'path';
import { Construct } from 'constructs';

export class TpotBookingStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props?: cdk.StackProps) {
    super(scope, id, props);

    // ─── DynamoDB Tables ───────────────────────────────────────────────

    const bookingTable = new dynamodb.Table(this, 'BookingTable', {
      tableName: 'TpotBookingTable',
      partitionKey: { name: 'bookingId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    bookingTable.addGlobalSecondaryIndex({
      indexName: 'instanceType-status-index',
      partitionKey: { name: 'instanceType', type: dynamodb.AttributeType.STRING },
      sortKey: { name: 'status', type: dynamodb.AttributeType.STRING },
      projectionType: dynamodb.ProjectionType.ALL,
    });

    const notificationConfigTable = new dynamodb.Table(this, 'NotificationConfigTable', {
      tableName: 'TpotNotificationConfigTable',
      partitionKey: { name: 'configId', type: dynamodb.AttributeType.STRING },
      billingMode: dynamodb.BillingMode.PAY_PER_REQUEST,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
    });

    // ─── SNS Topic ─────────────────────────────────────────────────────

    const notificationTopic = new sns.Topic(this, 'NotificationTopic', {
      topicName: 'TpotBookingNotifications',
      displayName: 'T-POT Booking Notifications',
    });

    // ─── S3 Bucket + CloudFront for SPA ────────────────────────────────

    const frontendBucket = new s3.Bucket(this, 'FrontendBucket', {
      bucketName: `tpot-booking-frontend-${this.account}`,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
    });

    const distribution = new cloudfront.Distribution(this, 'FrontendDistribution', {
      defaultBehavior: {
        origin: origins.S3BucketOrigin.withOriginAccessControl(frontendBucket),
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
      },
      defaultRootObject: 'index.html',
      errorResponses: [
        {
          httpStatus: 403,
          responseHttpStatus: 200,
          responsePagePath: '/index.html',
          ttl: cdk.Duration.minutes(5),
        },
        {
          httpStatus: 404,
          responseHttpStatus: 200,
          responsePagePath: '/index.html',
          ttl: cdk.Duration.minutes(5),
        },
      ],
    });

    // ─── Frontend Deployment ───────────────────────────────────────────

    new s3deploy.BucketDeployment(this, 'FrontendDeployment', {
      sources: [s3deploy.Source.asset(path.join(__dirname, '../frontend/dist'))],
      destinationBucket: frontendBucket,
      distribution,
      distributionPaths: ['/*'],
    });

    // ─── SSM Parameter for Basic Auth ──────────────────────────────────

    const basicAuthParam = ssm.StringParameter.fromSecureStringParameterAttributes(
      this,
      'BasicAuthCredentials',
      {
        parameterName: '/tpot-booking/basic-auth-credentials',
      },
    );

    // ─── Lambda Authorizer ─────────────────────────────────────────────

    const authorizerFunction = new lambda.Function(this, 'AuthorizerFunction', {
      functionName: 'tpot-booking-authorizer',
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'index.handler',
      code: lambda.Code.fromInline(`
import json
import base64
import os
import boto3

ssm = boto3.client('ssm')

def handler(event, context):
    token = event.get('authorizationToken', '')
    method_arn = event.get('methodArn', '')

    try:
        # Get credentials from SSM
        resp = ssm.get_parameter(
            Name='/tpot-booking/basic-auth-credentials',
            WithDecryption=True
        )
        # Expected format: "username:password"
        expected_creds = resp['Parameter']['Value']

        # Parse Basic auth header
        if token.startswith('Basic '):
            decoded = base64.b64decode(token[6:]).decode('utf-8')
        else:
            decoded = ''

        if decoded == expected_creds:
            return generate_policy('user', 'Allow', method_arn)
        else:
            return generate_policy('user', 'Deny', method_arn)
    except Exception as e:
        print(f'Auth error: {e}')
        return generate_policy('user', 'Deny', method_arn)


def generate_policy(principal_id, effect, resource):
    # Allow all methods under the same API stage
    arn_parts = resource.split(':')
    region = arn_parts[3]
    account_id = arn_parts[4]
    api_gw_arn = arn_parts[5].split('/')
    api_id = api_gw_arn[0]
    stage = api_gw_arn[1]
    wildcard_resource = f'arn:aws:execute-api:{region}:{account_id}:{api_id}/{stage}/*'

    return {
        'principalId': principal_id,
        'policyDocument': {
            'Version': '2012-10-17',
            'Statement': [{
                'Action': 'execute-api:Invoke',
                'Effect': effect,
                'Resource': wildcard_resource,
            }]
        }
    }
`),
      timeout: cdk.Duration.seconds(10),
    });

    basicAuthParam.grantRead(authorizerFunction);

    // ─── API Gateway ───────────────────────────────────────────────────

    const authorizer = new apigateway.TokenAuthorizer(this, 'BasicAuthAuthorizer', {
      handler: authorizerFunction,
      identitySource: 'method.request.header.Authorization',
      resultsCacheTtl: cdk.Duration.minutes(5),
    });

    const api = new apigateway.RestApi(this, 'BookingApi', {
      restApiName: 'TpotBookingApi',
      description: 'T-POT GPU Booking Platform API',
      defaultMethodOptions: {
        authorizer,
        authorizationType: apigateway.AuthorizationType.CUSTOM,
      },
      defaultCorsPreflightOptions: {
        allowOrigins: apigateway.Cors.ALL_ORIGINS,
        allowMethods: apigateway.Cors.ALL_METHODS,
        allowHeaders: ['Content-Type', 'Authorization'],
      },
    });

    // ─── Lambda Functions (Placeholders) ───────────────────────────────

    // API Handler Lambda
    const apiHandlerRole = new iam.Role(this, 'ApiHandlerRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    apiHandlerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'dynamodb:GetItem',
        'dynamodb:PutItem',
        'dynamodb:UpdateItem',
        'dynamodb:DeleteItem',
        'dynamodb:Query',
        'dynamodb:Scan',
      ],
      resources: [
        bookingTable.tableArn,
        `${bookingTable.tableArn}/index/*`,
        notificationConfigTable.tableArn,
      ],
    }));

    apiHandlerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['sns:Publish'],
      resources: [notificationTopic.topicArn],
    }));

    apiHandlerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ssm:GetParameter',
        'ssm:GetParameters',
      ],
      resources: [`arn:aws:ssm:${this.region}:${this.account}:parameter/tpot-booking/*`],
    }));

    apiHandlerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject', 's3:PutObject'],
      resources: [`${frontendBucket.bucketArn}/*`],
    }));

    apiHandlerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ec2:TerminateInstances',
        'ec2:DescribeInstances',
        'ec2:DescribeSecurityGroups',
        'ec2:CreateSecurityGroup',
        'ec2:DeleteSecurityGroup',
        'ec2:AuthorizeSecurityGroupIngress',
        'ec2:RevokeSecurityGroupIngress',
        'ec2:ModifyInstanceAttribute',
        'ec2:CreateTags',
      ],
      resources: ['*'],
    }));

    const apiHandler = new lambda.Function(this, 'ApiHandler', {
      functionName: 'tpot-booking-api-handler',
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset('./lambda/api'),
      role: apiHandlerRole,
      timeout: cdk.Duration.seconds(30),
      environment: {
        BOOKING_TABLE: bookingTable.tableName,
        NOTIFICATION_CONFIG_TABLE: notificationConfigTable.tableName,
        NOTIFICATION_TOPIC_ARN: notificationTopic.topicArn,
      },
    });

    // Capacity Poller Lambda
    const capacityPollerRole = new iam.Role(this, 'CapacityPollerRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    capacityPollerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ec2:RunInstances',
        'ec2:TerminateInstances',
        'ec2:DescribeInstances',
        'ec2:DescribeInstanceStatus',
        'ec2:DescribeSpotInstanceRequests',
        'ec2:RequestSpotInstances',
        'ec2:CancelSpotInstanceRequests',
        'ec2:CreateTags',
      ],
      resources: ['*'],
    }));

    capacityPollerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'dynamodb:GetItem',
        'dynamodb:PutItem',
        'dynamodb:UpdateItem',
        'dynamodb:Query',
        'dynamodb:Scan',
      ],
      resources: [
        bookingTable.tableArn,
        `${bookingTable.tableArn}/index/*`,
      ],
    }));

    capacityPollerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['sns:Publish'],
      resources: [notificationTopic.topicArn],
    }));

    capacityPollerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ssm:GetParameter',
        'ssm:GetParameters',
      ],
      resources: [`arn:aws:ssm:*:${this.account}:parameter/tpot-booking/*`],
    }));

    capacityPollerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['iam:PassRole'],
      resources: [`arn:aws:iam::${this.account}:role/tpot-bench-ec2-role`],
    }));

    const capacityPoller = new lambda.Function(this, 'CapacityPoller', {
      functionName: 'tpot-booking-capacity-poller',
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset('./lambda/poller'),
      role: capacityPollerRole,
      timeout: cdk.Duration.minutes(5),
      environment: {
        BOOKING_TABLE: bookingTable.tableName,
        NOTIFICATION_TOPIC_ARN: notificationTopic.topicArn,
        INSTANCE_PROFILE: 'tpot-bench-ec2-profile',
        SECURITY_GROUP: 'tpot-bench-noingress-sg',
        REGIONS: 'us-east-1,us-east-2,us-west-2',
      },
    });

    // Deployer Lambda
    const deployerRole = new iam.Role(this, 'DeployerRole', {
      assumedBy: new iam.ServicePrincipal('lambda.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('service-role/AWSLambdaBasicExecutionRole'),
      ],
    });

    deployerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ec2:DescribeInstances',
        'ec2:AuthorizeSecurityGroupIngress',
        'ec2:RevokeSecurityGroupIngress',
        'ec2:DescribeSecurityGroups',
        'ec2:CreateSecurityGroup',
        'ec2:DeleteSecurityGroup',
      ],
      resources: ['*'],
    }));

    deployerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'dynamodb:GetItem',
        'dynamodb:PutItem',
        'dynamodb:UpdateItem',
        'dynamodb:Query',
      ],
      resources: [
        bookingTable.tableArn,
        `${bookingTable.tableArn}/index/*`,
      ],
    }));

    deployerRole.addToPolicy(new iam.PolicyStatement({
      actions: ['sns:Publish'],
      resources: [notificationTopic.topicArn],
    }));

    deployerRole.addToPolicy(new iam.PolicyStatement({
      actions: [
        'ssm:GetParameter',
        'ssm:SendCommand',
        'ssm:GetCommandInvocation',
      ],
      resources: ['*'],
    }));

    const deployer = new lambda.Function(this, 'DeployerFunction', {
      functionName: 'tpot-booking-deployer',
      runtime: lambda.Runtime.PYTHON_3_12,
      handler: 'handler.handler',
      code: lambda.Code.fromAsset('./lambda/deployer'),
      role: deployerRole,
      timeout: cdk.Duration.minutes(10),
      environment: {
        BOOKING_TABLE: bookingTable.tableName,
        NOTIFICATION_TOPIC_ARN: notificationTopic.topicArn,
      },
    });

    // ─── EventBridge Rules ─────────────────────────────────────────────

    // Schedule rule to trigger capacity poller every minute
    new events.Rule(this, 'CapacityPollerSchedule', {
      ruleName: 'tpot-booking-capacity-poller-schedule',
      description: 'Trigger capacity poller Lambda every minute to scan for spot instances',
      schedule: events.Schedule.rate(cdk.Duration.minutes(1)),
      targets: [new targets.LambdaFunction(capacityPoller)],
    });

    // EC2 state change rule to trigger deployer when instance reaches running
    new events.Rule(this, 'DeployerEc2StateChangeRule', {
      ruleName: 'tpot-booking-deployer-ec2-state-change',
      description: 'Trigger deployer Lambda when EC2 instances reach running state',
      eventPattern: {
        source: ['aws.ec2'],
        detailType: ['EC2 Instance State-change Notification'],
        detail: {
          state: ['running'],
        },
      },
      targets: [new targets.LambdaFunction(deployer)],
    });

    // ─── EC2 Instance Profile for SSM ──────────────────────────────────

    const ec2Role = new iam.Role(this, 'TpotBenchEc2Role', {
      roleName: 'tpot-bench-ec2-role',
      assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
      managedPolicies: [
        iam.ManagedPolicy.fromAwsManagedPolicyName('AmazonSSMManagedInstanceCore'),
      ],
    });

    ec2Role.addToPolicy(new iam.PolicyStatement({
      actions: ['s3:GetObject'],
      resources: ['arn:aws:s3:::tpot-bench-scripts/*'],
    }));

    new iam.CfnInstanceProfile(this, 'TpotBenchEc2Profile', {
      instanceProfileName: 'tpot-bench-ec2-profile',
      roles: [ec2Role.roleName],
    });

    // ─── API Gateway Integration ───────────────────────────────────────

    const apiIntegration = new apigateway.LambdaIntegration(apiHandler);

    // /bookings resource
    const bookings = api.root.addResource('bookings');
    bookings.addMethod('GET', apiIntegration);
    bookings.addMethod('POST', apiIntegration);

    const bookingById = bookings.addResource('{bookingId}');
    bookingById.addMethod('GET', apiIntegration);
    bookingById.addMethod('PUT', apiIntegration);
    bookingById.addMethod('DELETE', apiIntegration);

    // /notifications resource
    const notifications = api.root.addResource('notifications');
    notifications.addMethod('GET', apiIntegration);
    notifications.addMethod('POST', apiIntegration);
    notifications.addMethod('PUT', apiIntegration);

    // /notifications/test-webhook resource
    const testWebhook = notifications.addResource('test-webhook');
    testWebhook.addMethod('POST', apiIntegration);

    // /status resource
    const status = api.root.addResource('status');
    status.addMethod('GET', apiIntegration);

    // ─── CDK Outputs ───────────────────────────────────────────────────

    new cdk.CfnOutput(this, 'ApiUrl', {
      value: api.url,
      description: 'API Gateway URL',
      exportName: 'TpotBookingApiUrl',
    });

    new cdk.CfnOutput(this, 'CloudFrontDomain', {
      value: distribution.distributionDomainName,
      description: 'CloudFront distribution domain name',
      exportName: 'TpotBookingCloudFrontDomain',
    });

    new cdk.CfnOutput(this, 'BookingTableName', {
      value: bookingTable.tableName,
      description: 'Booking DynamoDB table name',
      exportName: 'TpotBookingTableName',
    });

    new cdk.CfnOutput(this, 'NotificationConfigTableName', {
      value: notificationConfigTable.tableName,
      description: 'Notification config DynamoDB table name',
      exportName: 'TpotNotificationConfigTableName',
    });

    new cdk.CfnOutput(this, 'NotificationTopicArn', {
      value: notificationTopic.topicArn,
      description: 'SNS notification topic ARN',
      exportName: 'TpotBookingNotificationTopicArn',
    });

    new cdk.CfnOutput(this, 'FrontendBucketName', {
      value: frontendBucket.bucketName,
      description: 'Frontend S3 bucket name',
      exportName: 'TpotBookingFrontendBucketName',
    });
  }
}
