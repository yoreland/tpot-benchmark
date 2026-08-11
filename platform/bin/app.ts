#!/usr/bin/env node
import * as cdk from 'aws-cdk-lib';
import { TpotBookingStack } from '../lib/tpot-booking-stack';

const app = new cdk.App();
new TpotBookingStack(app, 'TpotBookingStack', {
  env: {
    account: '077090643075',
    region: 'us-east-1',
  },
  description: 'T-POT one-click GPU booking platform',
});
