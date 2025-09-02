//
// Copyright 2023 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

#import <SignalServiceKit/TSOutgoingMessage.h>

NS_ASSUME_NONNULL_BEGIN

@class TSContactThread;

@interface OWSProfileKeyRequestMessage : TSOutgoingMessage

- (instancetype)initWithThread:(TSContactThread *)thread
                   transaction:(DBReadTransaction *)transaction;

@end

NS_ASSUME_NONNULL_END
