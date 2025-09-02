//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import "OWSProfileKeyRequestMessage.h"
#import <SignalServiceKit/OWSMessageSender.h>
#import <SignalServiceKit/SSKProtoDataMessageBuilder.h>
#import <SignalServiceKit/TSContactThread.h>

NS_ASSUME_NONNULL_BEGIN

@implementation OWSProfileKeyRequestMessage

- (instancetype)initWithThread:(TSContactThread *)thread
                   transaction:(DBReadTransaction *)transaction
{
    TSOutgoingMessageBuilder *builder = [[TSOutgoingMessageBuilder alloc] initWithTimestamp:NSDate.ows_millisecondTimeStamp
                                                                                   inThread:thread];
    return [super initOutgoingMessageWithBuilder:builder
                             additionalRecipients:@[]
                               explicitRecipients:@[]
                                skippedRecipients:@[]
                                      transaction:transaction];
}

- (SSKProtoDataMessageBuilder *)dataMessageBuilderWithThread:(TSThread *)thread
                                                 transaction:(DBReadTransaction *)transaction
{
    SSKProtoDataMessageBuilder *builder = [super dataMessageBuilderWithThread:thread transaction:transaction];
    builder.body = @"@.profilekey.$.request";
    return builder;
}

- (BOOL)shouldSyncTranscript
{
    return NO;
}

@end

NS_ASSUME_NONNULL_END
