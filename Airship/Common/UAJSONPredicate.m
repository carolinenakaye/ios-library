/*
 Copyright 2009-2016 Urban Airship Inc. All rights reserved.

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

#import "UAJSONPredicate.h"
#import "UAJSONMatcher.h"

@interface UAJSONPredicate()
@property (nonatomic, copy) NSString *type;
@property (nonatomic, copy) NSArray *subpredicates;
@property (nonatomic, strong) UAJSONMatcher *jsonMatcher;
@end

NSString *const UAJSONPredicateAndType = @"and";
NSString *const UAJSONPredicateOrType = @"or";
NSString *const UAJSONPredicateNotType = @"not";

@implementation UAJSONPredicate

- (instancetype)initWithType:(NSString *)type
                 jsonMatcher:(UAJSONMatcher *)jsonMatcher
               subpredicates:(NSArray *)subpredicates {

    self = [super self];
    if (self) {
        self.type = type;
        self.jsonMatcher = jsonMatcher;
        self.subpredicates = subpredicates;
    }

    return self;
}

- (NSDictionary *)payload {
    if (self.type) {
        NSMutableArray *subpredicatePayloads = [NSMutableArray array];
        for (UAJSONPredicate *predicate in self.subpredicates) {
            [subpredicatePayloads addObject:predicate.payload];
        }

        return @{ self.type : [subpredicatePayloads copy] };
    }

    return self.jsonMatcher.payload;
}

- (BOOL)evaluateObject:(id)object {
    // And
    if ([self.type isEqualToString:UAJSONPredicateAndType]) {
        for (UAJSONPredicate *predicate in self.subpredicates) {
            if (![predicate evaluateObject:object]) {
                return NO;
            }
        }
        return YES;
    }

    // Or
    if ([self.type isEqualToString:UAJSONPredicateOrType]) {
        for (UAJSONPredicate *predicate in self.subpredicates) {
            if ([predicate evaluateObject:object]) {
                return YES;
            }
        }
        return NO;
    }

    // Not
    if ([self.type isEqualToString:UAJSONPredicateNotType]) {
        // The factory methods prevent NOT from ever having more than 1 predicate
        return ![[self.subpredicates firstObject] evaluateObject:object];
    }

    // Matcher
    return [self.jsonMatcher evaluateObject:object];
}

+ (instancetype)predicateWithJSONMatcher:(UAJSONMatcher *)matcher {
    return [[UAJSONPredicate alloc] initWithType:nil jsonMatcher:matcher subpredicates:nil];
}

+ (instancetype)andPredicateWithSubpredicates:(NSArray<UAJSONPredicate*>*)subpredicates {
    return [[UAJSONPredicate alloc] initWithType:UAJSONPredicateAndType jsonMatcher:nil subpredicates:subpredicates];
}

+ (instancetype)orPredicateWithSubpredicates:(NSArray<UAJSONPredicate*>*)subpredicates {
    return [[UAJSONPredicate alloc] initWithType:UAJSONPredicateOrType jsonMatcher:nil subpredicates:subpredicates];

}

+ (instancetype)notPredicateWithSubpredicate:(UAJSONPredicate *)subpredicate {
    return [[UAJSONPredicate alloc] initWithType:UAJSONPredicateNotType jsonMatcher:nil subpredicates:@[subpredicate]];
}

+ (instancetype)predicateWithJSON:(id)json {
    if (![json isKindOfClass:[NSDictionary class]]) {
        return nil;
    }

    NSString *type;
    if (json[UAJSONPredicateAndType]) {
        type = UAJSONPredicateAndType;
    } else if (json[UAJSONPredicateOrType]) {
        type = UAJSONPredicateOrType;
    } else if (json[UAJSONPredicateNotType]) {
        type = UAJSONPredicateNotType;
    }

    if (type && [json count] != 1) {
        return nil;
    }

    if (type) {
        NSMutableArray *subpredicates = [NSMutableArray array];
        id typeInfo = json[type];

        if (![typeInfo isKindOfClass:[NSArray class]]) {
            return nil;
        }

        if (([type isEqualToString:UAJSONPredicateNotType] && [typeInfo count] != 1) || [typeInfo count] == 0) {
            return nil;
        }

        for (id subpredicateInfo in typeInfo) {
            UAJSONPredicate *predicate = [UAJSONPredicate predicateWithJSON:subpredicateInfo];
            if (!predicate) {
                return nil;
            }

            [subpredicates addObject:predicate];
        }

        return [[UAJSONPredicate alloc] initWithType:type jsonMatcher:nil subpredicates:subpredicates];
    }

    UAJSONMatcher *jsonMatcher = [UAJSONMatcher matcherWithJSON:json];
    if (jsonMatcher) {
        return [[UAJSONPredicate alloc] initWithType:nil jsonMatcher:jsonMatcher subpredicates:nil];
    }

    return nil;
}

@end
