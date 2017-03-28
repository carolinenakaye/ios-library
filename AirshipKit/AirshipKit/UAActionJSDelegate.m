/*
 Copyright 2009-2017 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC ``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "UAActionJSDelegate.h"
#import "UAGlobal.h"

#import "NSJSONSerialization+UAAdditions.h"
#import "NSString+UAURLEncoding.h"

#import "UAActionRunner.h"
#import "UAWebViewCallData.h"

#import "UAWKWebViewDelegate.h"
#import "UARichContentWindow.h"

@implementation UAActionJSDelegate

+ (id)objectForEncodedArguments:(NSString *)arguments {
    NSString *urlDecodedArgs = [arguments urlDecodedStringWithEncoding:NSUTF8StringEncoding];
    if (!urlDecodedArgs) {
        UA_LDEBUG(@"unable to url decode action args: %@", arguments);
        return nil;
    }
    //allow the reading of fragments so we can parse lower level JSON values
    id jsonDecodedArgs = [NSJSONSerialization objectWithString:urlDecodedArgs
                                                       options: NSJSONReadingMutableContainers | NSJSONReadingAllowFragments];
    if (!jsonDecodedArgs) {
        UA_LDEBUG(@"unable to json decode action args: %@", urlDecodedArgs);
    } else {
        UA_LDEBUG(@"action arguments value: %@", jsonDecodedArgs);
    }
    return jsonDecodedArgs;
}

- (NSDictionary *)metadataWithCallData:(UAWebViewCallData *)data {
    NSMutableDictionary *metadata = [NSMutableDictionary dictionary];
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
    [metadata setValue:data.webView forKey:UAActionMetadataWebViewKey];
#pragma GCC diagnostic pop
    [metadata setValue:data.message forKey:UAActionMetadataInboxMessageKey];
    return metadata;
}

/**
 * Runs an action with a given value and performs a callback on completion.
 *
 * @param actionName The name of the action to perform
 * @param actionValue The action argument's value
 * @param metadata Optional metadata to pass to the action arguments.
 * @param callbackID A callback identifier generated in the JS layer. This can be `nil`.
 * @param completionHandler The completion handler passed in the JS delegate call.
 */
- (void)runAction:(NSString *)actionName
      actionValue:(id)actionValue
         metadata:(NSDictionary *)metadata
       callbackID:(NSString *)callbackID
completionHandler:(UAJavaScriptDelegateCompletionHandler)completionHandler {

    // JSONify the callback ID
    callbackID = [NSJSONSerialization stringWithObject:callbackID acceptingFragments:YES];

    UAActionCompletionHandler actionCompletionHandler = ^(UAActionResult *result) {
        UA_LDEBUG("Action %@ finished executing with status %ld", actionName, (long)result.status);
        if (!callbackID) {
            if (completionHandler) {
                completionHandler(nil);
            }
            return;
        }

        NSString *script;
        NSString *resultString;
        NSString *errorMessage;

        switch (result.status) {
            case UAActionStatusCompleted:
            {
                if (result.value) {
                    NSError *error;
                    //if the action completed with a result value, serialize into JSON
                    //accepting fragments so we can write lower level JSON values
                    resultString = [NSJSONSerialization stringWithObject:result.value acceptingFragments:YES error:&error];
                    // If there was an error serializing, fall back to a string description.
                    if (error) {
                        UA_LDEBUG(@"Unable to serialize result value %@, falling back to string description", result.value);
                        // JSONify the result string
                        resultString = [NSJSONSerialization stringWithObject:[result.value description] acceptingFragments:YES];
                    }
                }
                //in the case where there is no result value, pass null
                resultString = resultString ?: @"null";
                break;
            }
            case UAActionStatusActionNotFound:
                errorMessage = [NSString stringWithFormat:@"No action found with name %@, skipping action.", actionName];
                break;
            case UAActionStatusError:
                errorMessage = result.error.localizedDescription;
                break;
            case UAActionStatusArgumentsRejected:
                errorMessage = [NSString stringWithFormat:@"Action %@ rejected arguments.", actionName];
                break;
        }

        if (errorMessage) {
            // JSONify the error message
            errorMessage = [NSJSONSerialization stringWithObject:errorMessage acceptingFragments:YES];
            script = [NSString stringWithFormat:@"var error = new Error();\
                                                  error.message = %@; \
                                                  UAirship.finishAction(error, null, %@)", errorMessage, callbackID];
        } else if (resultString) {
            script = [NSString stringWithFormat:@"UAirship.finishAction(null, %@, %@);", resultString, callbackID];
        }

        if (completionHandler) {
            completionHandler(script);
        }
    };

    [UAActionRunner runActionWithName:actionName
                                value:actionValue
                            situation:UASituationWebViewInvocation
                             metadata:metadata
                    completionHandler:actionCompletionHandler];
}

/**
 * Runs a dictionary of action names to an array of action values.
 * 
 * @param actionValues A map of action name to an array of action values.
 * @param metadata Optional metadata to pass to the action arguments.
 */
- (void)runActionsWithValues:(NSDictionary *)actionValues metadata:(NSDictionary *)metadata {
    for (NSString *actionName in actionValues) {
        for (id actionValue in actionValues[actionName]) {
            [UAActionRunner runActionWithName:actionName
                                        value:(actionValue == [NSNull null]) ? nil : actionValue
                                    situation:UASituationWebViewInvocation
                                     metadata:metadata
                            completionHandler:^(UAActionResult *result) {
                                if (result.status == UAActionStatusCompleted) {
                                    UA_LDEBUG(@"action %@ completed successfully", actionName);
                                } else {
                                    UA_LDEBUG(@"action %@ completed with an error", actionName);
                                }
                            }];
        }
    }
}


/**
 * Decodes options with basic URL or URL+json encoding
 *
 * @param callData The UAWebViewCallData
 * @param basicEncoding Boolean to select for basic encoding
 * @return A dictionary of action name to an array of action values.
 */
- (NSDictionary *)decodeActionValuesWithCallData:(UAWebViewCallData *)callData basicEncoding:(BOOL)basicEncoding {
    if (!callData.options.count) {
        UA_LERR(@"Error no options available to decode");
        return nil;
    }

    NSMutableDictionary *actionValues = [[NSMutableDictionary alloc] init];

    for (NSString *encodedActionName in callData.options) {

        NSString *actionName = [encodedActionName urlDecodedStringWithEncoding:NSUTF8StringEncoding];
        if (!actionName.length) {
            UA_LDEBUG(@"Error decoding action name: %@", encodedActionName);
            return nil;
        }

        NSMutableArray *values = [NSMutableArray array];

        for (id encodedValue in callData.options[encodedActionName]) {

            if (!encodedValue || encodedValue == [NSNull null]) {
                 [values addObject:[NSNull null]];
                continue;
            }

            id value;
            if (basicEncoding) {
                value = [encodedValue urlDecodedStringWithEncoding:NSUTF8StringEncoding];
            } else {
                value = [UAActionJSDelegate objectForEncodedArguments:encodedValue];
            }

            if (!value) {
                UA_LERR(@"Error decoding arguments: %@", encodedValue);
                return nil;
            }

            [values addObject:value];
        }

        actionValues[actionName] = values;
    }

    return actionValues;
}

- (void)callWithData:(UAWebViewCallData *)data withCompletionHandler:(UAJavaScriptDelegateCompletionHandler)completionHandler {
    UA_LDEBUG(@"action js delegate name: %@ \n arguments: %@ \n options: %@", data.name, data.arguments, data.options);

    /*
     * run-action-cb performs a single action and calls the completion handler with
     * the result of the action. The action's value is JSON encoded.
     *
     * Expected format:
     * run-action-cb/<actionName>/<actionValue>/<callbackID>
     */

    if ([data.name isEqualToString:@"run-action-cb"]) {
        if (data.arguments.count != 3) {
            UA_LDEBUG(@"Unable to run-action-cb, wrong number of arguments. %@", data.arguments);
            if (completionHandler) {
                completionHandler(nil);
            }
            return;
        }

        NSString *actionName = [data.arguments[0] urlDecodedStringWithEncoding:NSUTF8StringEncoding];
        id actionValue = [UAActionJSDelegate objectForEncodedArguments:data.arguments[1]];
        NSString *callbackID = [data.arguments[2] urlDecodedStringWithEncoding:NSUTF8StringEncoding];


        // Run the action
        [self runAction:actionName
            actionValue:(actionValue == [NSNull null]) ? nil : actionValue
               metadata:[self metadataWithCallData:data]
             callbackID:callbackID
      completionHandler:completionHandler];

        return;
    }

    /*
     * run-actions performs several actions with the values JSON encoded.
     *
     * Expected format:
     * run-actions?<actionName>=<actionValue>&<anotherActionName>=<anotherActionValue>...
     */
    if ([data.name isEqualToString:@"run-actions"]) {


        [self runActionsWithValues:[self decodeActionValuesWithCallData:data basicEncoding:NO]
                         metadata:[self metadataWithCallData:data]];

        if (completionHandler) {
            completionHandler(nil);
        }


        return;
    }

    /*
     * run-basic-actions performs several actions with basic encoded action values.
     *
     * Expected format:
     * run-basic-actions?<actionName>=<actionValue>&<anotherActionName>=<anotherActionValue>...
     */
    if ([data.name isEqualToString:@"run-basic-actions"]) {

        [self runActionsWithValues:[self decodeActionValuesWithCallData:data basicEncoding:YES]
                          metadata:[self metadataWithCallData:data]];

        if (completionHandler) {
            completionHandler(nil);
        }

        return;
    }

    /**
     * close tries to invoke the closeWindowAnimated:
     *
     * Expected format:
     * close
     */
    if ([data.name isEqualToString:@"close"]) {
        id delegate = data.delegate;
        if ([delegate respondsToSelector:@selector(closeWindowAnimated:)]) {
            [delegate closeWindowAnimated:YES];
        } else {
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
            UIWebView *webView = data.webView;
            if (webView != nil) {
                id webViewDelegate = webView.delegate;
                if ([webViewDelegate respondsToSelector:@selector(closeWebView:animated:)]) {
                    UA_LIMPERR(@"closeWebView:animated: will be removed in SDK version 9.0");
                    [webViewDelegate closeWebView:webView animated:YES];
                }
#pragma GCC diagnostic pop
            }
        }

        if (completionHandler) {
            completionHandler(nil);
        }

        return;
    }

    // Arguments not recognized, pass a nil script result
    if (completionHandler) {
        completionHandler(nil);
    }
}

@end
