#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { TpotBookingStack } from '../lib/tpot-booking-stack';

const app = new cdk.App();

const account = app.node.tryGetContext('account') || process.env.CDK_DEFAULT_ACCOUNT || '077090643075';
const region = app.node.tryGetContext('region') || process.env.CDK_DEFAULT_REGION || 'us-east-1';

new TpotBookingStack(app, 'TpotBookingStack', {
  env: {
    account,
    region,
  },
  description: 'T-POT one-click GPU booking platform',
});
