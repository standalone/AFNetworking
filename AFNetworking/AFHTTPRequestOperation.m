// AFHTTPRequestOperation.m
//
// Copyright (c) 2011 Gowalla (http://gowalla.com/)
// 
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// 
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// 
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

#import "AFHTTPRequestOperation.h"
#import <objc/runtime.h>

NSSet * AFContentTypesFromHTTPHeader(NSString *string) {
    static NSCharacterSet *_skippedCharacterSet = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _skippedCharacterSet = [[NSCharacterSet characterSetWithCharactersInString:@" ,"] retain];
    });
    
    if (!string) {
        return nil;
    }
    
    NSScanner *scanner = [NSScanner scannerWithString:string];
    scanner.charactersToBeSkipped = _skippedCharacterSet;
    
    NSMutableSet *mutableContentTypes = [NSMutableSet set];
    while (![scanner isAtEnd]) {
        NSString *contentType = nil;
        if ([scanner scanUpToString:@";" intoString:&contentType]) {
            [scanner scanUpToString:@"," intoString:nil];
        }
        
        if (contentType) {
            [mutableContentTypes addObject:contentType];
        }
    }
    
    return [NSSet setWithSet:mutableContentTypes];
}

static void AFSwizzleClassMethodWithImplementation(Class klass, SEL selector, IMP implementation) {
    Method originalMethod = class_getClassMethod(klass, selector);
	if (method_getImplementation(originalMethod) != implementation) {
		class_replaceMethod(objc_getMetaClass([NSStringFromClass(klass) UTF8String]), selector, implementation, method_getTypeEncoding(originalMethod));
    }
}

static NSString * AFStringFromIndexSet(NSIndexSet *indexSet) {
    NSMutableString *string = [NSMutableString string];

    NSRange range = NSMakeRange([indexSet firstIndex], 1);
    while (range.location != NSNotFound) {
        NSUInteger nextIndex = [indexSet indexGreaterThanIndex:range.location];
        while (nextIndex == range.location + range.length) {
            range.length++;
            nextIndex = [indexSet indexGreaterThanIndex:nextIndex];
        }

        if (string.length) {
            [string appendString:@","];
        }

        if (range.length == 1) {
            [string appendFormat:@"%lu", (long)range.location];
        } else {
            NSUInteger firstIndex = range.location;
            NSUInteger lastIndex = firstIndex + range.length - 1;
            [string appendFormat:@"%lu-%lu", (long)firstIndex, (long)lastIndex];
        }

        range.location = nextIndex;
        range.length = 1;
    }

    return string;
}

#pragma mark -

@interface AFHTTPRequestOperation ()
@property (readwrite, nonatomic, retain) NSURLRequest *request;
@property (readwrite, nonatomic, retain) NSHTTPURLResponse *response;
@property (readwrite, nonatomic, retain) NSError *HTTPError;
@property (assign) long long totalContentLength;
@property (assign) long long offsetContentLength;
@end

@implementation AFHTTPRequestOperation
@synthesize HTTPError = _HTTPError;
@synthesize successCallbackQueue = _successCallbackQueue;
@synthesize failureCallbackQueue = _failureCallbackQueue;
@synthesize totalContentLength = _totalContentLength;
@synthesize offsetContentLength = _offsetContentLength;
@dynamic request;
@dynamic response;

- (void)dealloc {
    [_HTTPError release];
    
    if (_successCallbackQueue) { 
        dispatch_release(_successCallbackQueue);
        _successCallbackQueue = NULL;
    }
    
    if (_failureCallbackQueue) { 
        dispatch_release(_failureCallbackQueue); 
        _failureCallbackQueue = NULL;
    }

    [super dealloc];
}

- (NSError *)error {
    if (self.response && !self.HTTPError) {
        if (![self hasAcceptableStatusCode] || ![self hasAcceptableContentType]) {
            NSMutableDictionary *userInfo = [NSMutableDictionary dictionary];
            [userInfo setValue:self.responseString forKey:NSLocalizedRecoverySuggestionErrorKey];
            [userInfo setValue:[self.request URL] forKey:NSURLErrorFailingURLErrorKey];
            [userInfo setValue:self.request forKey:AFNetworkingOperationFailingURLRequestErrorKey];
            [userInfo setValue:self.response forKey:AFNetworkingOperationFailingURLResponseErrorKey];
            
            if (![self hasAcceptableStatusCode]) {
                NSUInteger statusCode = ([self.response isKindOfClass:[NSHTTPURLResponse class]]) ? (NSUInteger)[self.response statusCode] : 200;
                [userInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Expected status code in (%@), got %d", nil), AFStringFromIndexSet([[self class] acceptableStatusCodes]), statusCode] forKey:NSLocalizedDescriptionKey];
                self.HTTPError = [[[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:NSURLErrorBadServerResponse userInfo:userInfo] autorelease];
            } else if (![self hasAcceptableContentType]) {
                // Don't invalidate content type if there is no content
                if ([self.responseData length] > 0) {
                    [userInfo setValue:[NSString stringWithFormat:NSLocalizedString(@"Expected content type %@, got %@", nil), [[self class] acceptableContentTypes], [self.response MIMEType]] forKey:NSLocalizedDescriptionKey];
                    self.HTTPError = [[[NSError alloc] initWithDomain:AFNetworkingErrorDomain code:NSURLErrorCannotDecodeContentData userInfo:userInfo] autorelease];
                }
            }
        }
    }
    
    if (self.HTTPError) {
        return self.HTTPError;
    } else {
        return [super error];
    }
}

- (void)pause {
    unsigned long long offset = 0; 
    if ([self.outputStream propertyForKey:NSStreamFileCurrentOffsetKey]) {
        offset = [[self.outputStream propertyForKey:NSStreamFileCurrentOffsetKey] unsignedLongLongValue];
    } else {
        offset = [[self.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey] length];
    }

    NSMutableURLRequest *mutableURLRequest = [[self.request mutableCopy] autorelease];
    if ([[self.response allHeaderFields] valueForKey:@"ETag"]) {
        [mutableURLRequest setValue:[[self.response allHeaderFields] valueForKey:@"ETag"] forHTTPHeaderField:@"If-Range"];
    }
    [mutableURLRequest setValue:[NSString stringWithFormat:@"bytes=%llu-", offset] forHTTPHeaderField:@"Range"];
    self.request = mutableURLRequest;
    
    [super pause];
}

- (BOOL)hasAcceptableStatusCode {
	if (!self.response) {
		return NO;
	}
    
    NSUInteger statusCode = ([self.response isKindOfClass:[NSHTTPURLResponse class]]) ? (NSUInteger)[self.response statusCode] : 200;
    return ![[self class] acceptableStatusCodes] || [[[self class] acceptableStatusCodes] containsIndex:statusCode];
}

- (BOOL)hasAcceptableContentType {
    if (!self.response) {
		return NO;
	}
    
    return ![[self class] acceptableContentTypes] || [[[self class] acceptableContentTypes] containsObject:[self.response MIMEType]];
}

- (void)setSuccessCallbackQueue:(dispatch_queue_t)successCallbackQueue {
    if (successCallbackQueue != _successCallbackQueue) {
        if (_successCallbackQueue) {
            dispatch_release(_successCallbackQueue);
            _successCallbackQueue = NULL;
        }

        if (successCallbackQueue) {
            dispatch_retain(successCallbackQueue);
            _successCallbackQueue = successCallbackQueue;
        }
    }    
}

- (void)setFailureCallbackQueue:(dispatch_queue_t)failureCallbackQueue {
    if (failureCallbackQueue != _failureCallbackQueue) {
        if (_failureCallbackQueue) {
            dispatch_release(_failureCallbackQueue);
            _failureCallbackQueue = NULL;
        }
        
        if (failureCallbackQueue) {
            dispatch_retain(failureCallbackQueue);
            _failureCallbackQueue = failureCallbackQueue;
        }
    }    
}

- (void)setCompletionBlockWithSuccess:(void (^)(AFHTTPRequestOperation *operation, id responseObject))success
                              failure:(void (^)(AFHTTPRequestOperation *operation, NSError *error))failure
{
    self.completionBlock = ^ {
        if ([self isCancelled]) {
            return;
        }
        
        if (self.error) {
            if (failure) {
                dispatch_async(self.failureCallbackQueue ?: dispatch_get_main_queue(), ^{
                    failure(self, self.error);
                });
            }
        } else {
            if (success) {
                dispatch_async(self.successCallbackQueue ?: dispatch_get_main_queue(), ^{
                    success(self, self.responseData);
                });
            }
        }
    };
}

#pragma mark - AFHTTPRequestOperation

static id AFStaticClassValueImplementation(id self, SEL _cmd) {
	return objc_getAssociatedObject([self class], _cmd);
}

+ (NSIndexSet *)acceptableStatusCodes {
    return [NSIndexSet indexSetWithIndexesInRange:NSMakeRange(200, 100)];
}

+ (void)addAcceptableStatusCodes:(NSIndexSet *)statusCodes {
    NSMutableIndexSet *mutableStatusCodes = [[[NSMutableIndexSet alloc] initWithIndexSet:[self acceptableStatusCodes]] autorelease];
    [mutableStatusCodes addIndexes:statusCodes];
	SEL selector = @selector(acceptableStatusCodes);
	AFSwizzleClassMethodWithImplementation([self class], selector, (IMP)AFStaticClassValueImplementation);
	objc_setAssociatedObject([self class], selector, mutableStatusCodes, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (NSSet *)acceptableContentTypes {
    return nil;
}

+ (void)addAcceptableContentTypes:(NSSet *)contentTypes {
    NSMutableSet *mutableContentTypes = [[[NSMutableSet alloc] initWithSet:[self acceptableContentTypes] copyItems:YES] autorelease];
    [mutableContentTypes unionSet:contentTypes];
	SEL selector = @selector(acceptableContentTypes);
	AFSwizzleClassMethodWithImplementation([self class], selector, (IMP)AFStaticClassValueImplementation);
	objc_setAssociatedObject([self class], selector, mutableContentTypes, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

+ (BOOL)canProcessRequest:(NSURLRequest *)request {
    if ([[self class] isEqual:[AFHTTPRequestOperation class]]) {
        return YES;
    }
    
    return [[self acceptableContentTypes] intersectsSet:AFContentTypesFromHTTPHeader([request valueForHTTPHeaderField:@"Accept"])];
}

#pragma mark - NSURLConnectionDelegate

- (void)connection:(NSURLConnection *)connection 
didReceiveResponse:(NSURLResponse *)response 
{
    self.response = (NSHTTPURLResponse *)response;
    
    // Set Content-Range header if status code of response is 206 (Partial Content)
    // See http://www.w3.org/Protocols/rfc2616/rfc2616-sec10.html#sec10.2.7
    long long totalContentLength = self.response.expectedContentLength;
    long long fileOffset = 0;
    NSUInteger statusCode = ([self.response isKindOfClass:[NSHTTPURLResponse class]]) ? (NSUInteger)[self.response statusCode] : 200;
    if (statusCode == 206) {
        NSString *contentRange = [self.response.allHeaderFields valueForKey:@"Content-Range"];
        if ([contentRange hasPrefix:@"bytes"]) {
            NSArray *byteRanges = [contentRange componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" -/"]];
            if ([byteRanges count] == 4) {
                fileOffset = [[byteRanges objectAtIndex:1] longLongValue];
                totalContentLength = [[byteRanges objectAtIndex:2] longLongValue] ?: -1; // if this is "*", it's converted to 0, but -1 is default.
            }
        }
    } else {
        if ([self.outputStream propertyForKey:NSStreamFileCurrentOffsetKey]) {
            [self.outputStream setProperty:[NSNumber numberWithInteger:0] forKey:NSStreamFileCurrentOffsetKey];
        } else {
            if ([[self.outputStream propertyForKey:NSStreamDataWrittenToMemoryStreamKey] length] > 0) {
                self.outputStream = [NSOutputStream outputStreamToMemory];
            }
        }
    }
    
    self.offsetContentLength = MAX(fileOffset, 0);
    self.totalContentLength = totalContentLength;
    
    [self.outputStream open];
}


+ (AFHTTPRequestOperation *) HTTPRequestOperationWithRequest:(NSURLRequest *)urlRequest
													 success:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSData *data))success
													 failure:(void (^)(NSURLRequest *request, NSHTTPURLResponse *response, NSError *error))failure {
	AFHTTPRequestOperation *requestOperation = [[[AFHTTPRequestOperation alloc] initWithRequest:urlRequest] autorelease];
    [requestOperation setCompletionBlockWithSuccess:^(AFHTTPRequestOperation *operation, id responseObject) {
        if (success) success(operation.request, operation.response, responseObject);
    } failure:^(AFHTTPRequestOperation *operation, NSError *error) {
        if (failure) failure(operation.request, operation.response, error);
    }];
    
    
    return requestOperation;

}

@end
