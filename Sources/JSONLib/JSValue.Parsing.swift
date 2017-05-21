/* --------------------------------------------------------------------------------------------
 * Copyright (c) Kiad Studios, LLC. All rights reserved.
 * Licensed under the MIT License. See License in the project root for license information.
 * ------------------------------------------------------------------------------------------ */

import Foundation

extension JSValue {
    public static func parse(_ string: String) throws -> JSValue {
        let data = string.data(using: String.Encoding.utf8, allowLossyConversion: false)!
        return try data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> JSValue in
            let buffer = UnsafeBufferPointer(start: ptr, count: data.count)
            let generator = ReplayableGenerator(buffer)

            let value = try parse(generator)
            try validateRemainingContent(generator)
            return value
        }
    }

    public static func parse(_ data: Data) throws -> JSValue {
        return try data.withUnsafeBytes { (ptr: UnsafePointer<UInt8>) -> JSValue in
            let buffer = UnsafeBufferPointer(start: ptr, count: data.count)
            let generator = ReplayableGenerator(buffer)

            let value = try parse(generator)
            try validateRemainingContent(generator)
            return value
        }
    }

    /// Parses the given sequence of UTF8 code points and attempts to return a `JSValue` from it.
    /// - parameter seq: The sequence of UTF8 code points.
    /// - returns: A `JSParsingResult` containing the parsed `JSValue` or error information.
    public static func parse(_ bytes: [UInt8]) throws -> JSValue {
        return try bytes.withUnsafeBufferPointer { ptr in
            let generator = ReplayableGenerator(ptr)

            let value = try parse(generator)
            try validateRemainingContent(generator)
            return value
        }
    }

    static func validateRemainingContent(_ generator: ReplayableGenerator) throws {
        for codeunit in generator {
            if codeunit.isWhitespace() { continue }
            else {
                let remainingText = substring(generator)

                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Invalid characters after the last item in the JSON: \(remainingText)"]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
            }
        }
    }

    static func parse(_ generator: ReplayableGenerator) throws -> JSValue {
        for codeunit in generator {
            if codeunit.isWhitespace() { continue }

            if codeunit == Token.LeftCurly {
                return try JSValue.parseObject(generator)
            }
            else if codeunit == Token.LeftBracket {
                return try JSValue.parseArray(generator)
            }
            else if codeunit.isDigit() || codeunit == Token.Minus || codeunit == Token.Plus || codeunit == Token.Period {
                return try JSValue.parseNumber(generator)
            }
            else if codeunit == Token.t {
                return try JSValue.parseTrue(generator)
            }
            else if codeunit == Token.f {
                return try JSValue.parseFalse(generator)
            }
            else if codeunit == Token.n {
                return try JSValue.parseNull(generator)
            }
            else if codeunit == Token.DoubleQuote || codeunit == Token.SingleQuote {
                return try JSValue.parseString(generator, quote: codeunit)
            }
            else {
                break
            }
        }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "No valid JSON value was found to parse in string."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    enum ObjectParsingState {
        case initial
        case key
        case value
    }

    static func parseObject(_ generator: ReplayableGenerator) throws -> JSValue {
        var state = ObjectParsingState.initial

        var key = ""
        var dict = [String:JSValue]()

        for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit) {
            case (0, Token.LeftCurly): continue
            case (_, Token.RightCurly):
                switch state {
                case .initial: fallthrough
                case .value:
                    let _ = generator.next()        // eat the '}'
                    return JSValue(dict)

                default:
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Expected token '}' at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }

            case (_, Token.SingleQuote): fallthrough
            case (_, Token.DoubleQuote):
                switch state {
                case .initial:
                    state = .key

                    key = try parseString(generator, quote: codeunit).string!
                    generator.replay()

                default:
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Expected token ''' (single quote) or '\"' at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }

            case (_, Token.Colon):
                switch state {
                case .key:
                    state = .value

                    let _ = generator.next() // eat the ':'
                    let value = try parse(generator)
                    dict[key] = value
                    generator.replay()

                default:
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Expected token ':' at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }

            case (_, Token.Comma):
                switch state {
                case .value:
                    state = .initial
                    key = ""

                default:
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Expected token ',' at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }

            default:
                if codeunit.isWhitespace() { continue }
                else {
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }
            }
        }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse object. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    static func parseArray(_ generator: ReplayableGenerator) throws -> JSValue {
        var values = [JSValue]()
        var needsComma = false
        var lastParsedComma = false
    
        for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit) {
            case (0, Token.LeftBracket): continue
            case (_, Token.RightBracket):
                if lastParsedComma {
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "A trailing `,` is not supported. Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }
                let _ = generator.next()        // eat the ']'
                return JSValue(values)
            case (_, Token.Comma):
                if !needsComma {
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "A `,` can on separate values. Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }
                needsComma = false
                lastParsedComma = true

            default:
                if codeunit.isWhitespace() { continue }
                else {
                    if needsComma {
                        let info = [
                            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                            ErrorKeys.LocalizedFailureReason: "Unable to parse array. Expected `,` to separate values. Context: '\(contextualString(generator))'."]
                        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                    }
                    let value = try parse(generator)
                    values.append(value)
                    generator.replay()
                    needsComma = true
                    lastParsedComma = false
                }
            }
        }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse array. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    enum NumberParsingState {
        case initial
        case leadingZero
        case leadingNegativeSign
        case integer
        case decimal
        case fractional
        case exponent
        case exponentSign
        case exponentDigits
    }

    // Implementation Note: This is move outside here to avoid the re-allocation of this buffer each time.
    // This has a significant impact on performance.
    static var numberStorage: [UInt8] = []
    static func parseNumber(_ generator: ReplayableGenerator) throws -> JSValue {
        // The https://tools.ietf.org/html/rfc7159 spec for numbers.
        //    number = [ minus ] int [ frac ] [ exp ]
        //    decimal-point = %x2E       ; .
        //    digit1-9 = %x31-39         ; 1-9
        //    e = %x65 / %x45            ; e E
        //    exp = e [ minus / plus ] 1*DIGIT
        //    frac = decimal-point 1*DIGIT
        //    int = zero / ( digit1-9 *DIGIT )
        //    minus = %x2D               ; -
        //    plus = %x2B                ; +
        //    zero = %x30                ; 0

        numberStorage.removeAll(keepingCapacity: true)
        var state: NumberParsingState = .initial
        var valid = false

        loop: for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit, state) {

            case (_, Token.Minus, .initial):
                numberStorage.append(codeunit)
                state = .leadingNegativeSign
            
            case (_, Token.Plus, .initial):
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Leading plus is not supported. Index: \(idx). Token: \(codeunit). State: \(state). Context: '\(contextualString(generator))'."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            case (_, Token.Zero, .initial):
                numberStorage.append(codeunit)
                state = .leadingZero

            case (_, Token.Zero, .leadingNegativeSign):
                numberStorage.append(codeunit)
                state = .leadingZero

            case (_, Token.Zero...Token.Nine, .leadingZero):
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Leading zeros are not allowed."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            case (_, Token.One...Token.Nine, .leadingNegativeSign): fallthrough
            case (_, Token.One...Token.Nine, .initial):
                numberStorage.append(codeunit)
                state = .integer

            case (_, Token.Zero...Token.Nine, .decimal):
                numberStorage.append(codeunit)
                state = .fractional

            case (_, Token.Zero...Token.Nine, .integer): fallthrough
            case (_, Token.Zero...Token.Nine, .fractional):
                numberStorage.append(codeunit)

            case (_, Token.e, .leadingZero): fallthrough
            case (_, Token.E, .leadingZero): fallthrough
            case (_, Token.e, .integer): fallthrough
            case (_, Token.E, .integer): fallthrough
            case (_, Token.e, .fractional): fallthrough
            case (_, Token.E, .fractional):
                numberStorage.append(codeunit)
                state = .exponent

            case (_, Token.Minus, .exponent): fallthrough
            case (_, Token.Plus, .exponent):
                numberStorage.append(codeunit)
                state = .exponentSign
            
            case (_, Token.Zero...Token.Nine, .exponent): fallthrough
            case (_, Token.Zero...Token.Nine, .exponentSign): fallthrough
            case (_, Token.Zero...Token.Nine, .exponentDigits):
                numberStorage.append(codeunit)
                state = .exponentDigits

            case (_, Token.Period, .leadingZero): fallthrough
            case (_, Token.Period, .integer):
                numberStorage.append(codeunit)
                state = .decimal

            default:
                if codeunit.isValidTerminator() { generator.replay(); valid = true; break loop }
                else {
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx). Token: \(codeunit). State: \(state). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }
            }
        }

        if generator.atEnd() || valid {
            if state == .decimal {
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "A trailing period is not allowed."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            }

            let string = String(bytes: numberStorage, encoding: .utf8)
            if let number = Double(string!) {
                return JSValue(number)
            }
            else {
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Unable to convert parsed number into a `Double`: \(string!)."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
            }
        }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse array. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    static func parseTrue(_ generator: ReplayableGenerator) throws -> JSValue {
        for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit) {
            case (0, Token.t): continue
            case (1, Token.r): continue
            case (2, Token.u): continue
            case (3, Token.e): continue
            case (4, _):
                if codeunit.isValidTerminator() { return JSValue(true) }
                fallthrough

            default:
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
            }
        }

        if generator.atEnd() { return JSValue(true) }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse 'true' literal. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    static func parseFalse(_ generator: ReplayableGenerator) throws -> JSValue {
        for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit) {
            case (0, Token.f): continue
            case (1, Token.a): continue
            case (2, Token.l): continue
            case (3, Token.s): continue
            case (4, Token.e): continue
            case (5, _):
                if codeunit.isValidTerminator() { return JSValue(false) }
                fallthrough

            default:
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
            }
        }

        if generator.atEnd() { return JSValue(false) }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse 'false' literal. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    static func parseNull(_ generator: ReplayableGenerator) throws -> JSValue {
        for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit) {
            case (0, Token.n): continue
            case (1, Token.u): continue
            case (2, Token.l): continue
            case (3, Token.l): continue
            case (4, _):
                if codeunit.isValidTerminator() { return .null }
                fallthrough

            default:
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
            }
        }

        if generator.atEnd() { return .null }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse 'null' literal. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    fileprivate static func parseHexDigit(_ digit: UInt8) -> Int? {
        if Token.Zero <= digit && digit <= Token.Nine {
            return Int(digit) - Int(Token.Zero)
        } else if Token.a <= digit && digit <= Token.f {
            return 10 + Int(digit) - Int(Token.a)
        } else if Token.A <= digit && digit <= Token.F {
            return 10 + Int(digit) - Int(Token.A)
        } else {
            return nil
        }
    }

    // Implementation Note: This is move outside here to avoid the re-allocation of this buffer each time.
    // This has a significant impact on performance.
    static var stringStorage: [UInt8] = []
    static func parseString(_ generator: ReplayableGenerator, quote: UInt8) throws -> JSValue {
        stringStorage.removeAll(keepingCapacity: true)

        for (idx, codeunit) in generator.enumerated() {
            switch (idx, codeunit) {
            case (0, quote): continue
            case (_, quote):
                let _ = generator.next()        // eat the quote

                if let string = String(bytes: stringStorage, encoding: .utf8) {
                    return JSValue(string)
                }
                else {
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Unable to convert the parsed bytes into a string. Bytes: \(stringStorage)'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }
            
            case (_, Token.HorizontalTab):
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "An unescaped TAB character is not allowed in a string."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            case (_, Token.Linefeed):
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "An unescaped linefeed character is not allowed in a string."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            case (_, Token.CarriageReturn):
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "An unescaped carriage return character is not allowed in a string."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            case (_, Token.Formfeed):
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "An unescaped formfeed character is not allowed in a string."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)

            case (_, Token.Backslash):
                let next = generator.next()

                if let next = next {
                    switch next {

                    case Token.Backslash:
                        stringStorage.append(Token.Backslash)

                    case Token.Forwardslash:
                        stringStorage.append(Token.Forwardslash)

                    case quote:
                        stringStorage.append(Token.DoubleQuote)

                    case Token.n:
                        stringStorage.append(Token.Linefeed)

                    case Token.b:
                        stringStorage.append(Token.Backspace)

                    case Token.f:
                        stringStorage.append(Token.Formfeed)

                    case Token.r:
                        stringStorage.append(Token.CarriageReturn)

                    case Token.t:
                        stringStorage.append(Token.HorizontalTab)

                    case Token.u:
                            let codeunits: [UInt16]

                            let codeunit = try parseCodeUnit(generator)
                            if UTF16.isLeadSurrogate(codeunit) {
                                guard let next = generator.next() else {
                                    let info = [
                                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                                        ErrorKeys.LocalizedFailureReason: "Expected to find the second half of the surrogate pair."]
                                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                                }

                                if next != Token.Backslash {
                                    let info = [
                                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                                        ErrorKeys.LocalizedFailureReason: "Invalid unicode scalar, expected \\."]
                                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                                }

                                guard let next2 = generator.next() else {
                                    let info = [
                                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                                        ErrorKeys.LocalizedFailureReason: "Expected to find the second half of the surrogate pair."]
                                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                                }

                                if next2 != Token.u {
                                    let info = [
                                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                                        ErrorKeys.LocalizedFailureReason: "Invalid unicode scalar, expected u."]
                                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                                }

                                let codeunit2 = try parseCodeUnit(generator)
                                codeunits = [codeunit, codeunit2]
                            }
                            else {
                                codeunits = [codeunit]
                            }

                            let transcodingError = transcode(codeunits.makeIterator(),
                                                    from: UTF16.self,
                                                    to: UTF8.self,
                                                    stoppingOnError: true) { stringStorage.append($0) }

                            if transcodingError {
                                let info = [
                                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                                    ErrorKeys.LocalizedFailureReason: "Invalid unicode scalar"]
                                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                            }

                    default:
                        let info = [
                            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                            ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx + 1). Token: \(next). Context: '\(contextualString(generator))'."]
                        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                    }
                }
                else {
                    let info = [
                        ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                        ErrorKeys.LocalizedFailureReason: "Unexpected token at index: \(idx). Token: \(codeunit). Context: '\(contextualString(generator))'."]
                    throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
                }

            default:
                stringStorage.append(codeunit)
            }
        }

        let info = [
            ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
            ErrorKeys.LocalizedFailureReason: "Unable to parse string. Context: '\(contextualString(generator))'."]
        throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
    }

    static func parseCodeUnit(_ generator: ReplayableGenerator) throws -> UInt16 {
        let c1 = generator.next()
        let c2 = generator.next()
        let c3 = generator.next()
        let c4 = generator.next()

        switch (c1, c2, c3, c4) {
        case let (.some(c1), .some(c2), .some(c3), .some(c4)):
            let value1 = parseHexDigit(c1)
            let value2 = parseHexDigit(c2)
            let value3 = parseHexDigit(c3)
            let value4 = parseHexDigit(c4)

            if value1 == nil || value2 == nil || value3 == nil || value4 == nil {
                let info = [
                    ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                    ErrorKeys.LocalizedFailureReason: "Invalid unicode escape sequence"]
                throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
            }

            return UInt16((value1! << 12) | (value2! << 8) | (value3! << 4) | value4!)

        default:
            let info = [
                ErrorKeys.LocalizedDescription: ErrorCode.ParsingError.message,
                ErrorKeys.LocalizedFailureReason: "Invalid unicode escape sequence"]
            throw JsonParserError(code: ErrorCode.ParsingError.code, domain: JSValueErrorDomain, userInfo: info)
        }
    }

    // MARK: Helper functions

    static func substring(_ generator: ReplayableGenerator) -> String {
        var string = ""

        for codeunit in generator {
            string += String(codeunit)
        }

        return string
    }


    static func contextualString(_ generator: ReplayableGenerator, left: Int = 5, right: Int = 10) -> String {
        var string = ""

        for _ in 0..<left {
            generator.replay()
        }

        for _ in 0..<(left + right) {
            let codeunit = generator.next() ?? 0
            string += String(codeunit)
        }

        return string
    }

    static func exp(_ number: Double, _ exp: Int) -> Double {
        return exp < 0 ?
            (0 ..< abs(exp)).reduce(number, { x, _ in x / 10 }) :
            (0 ..< exp).reduce(number, { x, _ in x * 10 })
    }
}

extension UInt8 {

    /// Determines if the `UnicodeScalar` represents one of the standard Unicode whitespace characters.
    ///
    /// :return: `true` if the scalar is a Unicode whitespace character; `false` otherwise.
    func isWhitespace() -> Bool {
        if self >= 0x09 && self <= 0x0D        { return true }     // White_Space # Cc   [5] <control-0009>..<control-000D>
        if self == 0x20                        { return true }     // White_Space # Zs       SPACE
        if self == 0x85                        { return true }     // White_Space # Cc       <control-0085>
        if self == 0xA0                        { return true }     // White_Space # Zs       NO-BREAK SPACE

        // TODO: These are no longer possible to be hit... does it matter???
        //        if self == 0x1680                      { return true }     // White_Space # Zs       OGHAM SPACE MARK
        //        if self >= 0x2000 && self <= 0x200A    { return true }     // White_Space # Zs  [11] EN QUAD..HAIR SPACE
        //        if self == 0x2028                      { return true }     // White_Space # Zl       LINE SEPARATOR
        //        if self == 0x2029                      { return true }     // White_Space # Zp       PARAGRAPH SEPARATOR
        //        if self == 0x202F                      { return true }     // White_Space # Zs       NARROW NO-BREAK SPACE
        //        if self == 0x205F                      { return true }     // White_Space # Zs       MEDIUM MATHEMATICAL SPACE
        //        if self == 0x3000                      { return true }     // White_Space # Zs       IDEOGRAPHIC SPACE

        return false
    }

    /// Determines if the `UnicodeScalar` represents a numeric digit.
    ///
    /// :return: `true` if the scalar is a Unicode numeric character; `false` otherwise.
    func isDigit() -> Bool {
        return self >= Token.Zero && self <= Token.Nine
    }

    /// Determines if the `UnicodeScalar` represents a valid terminating character.
    /// :return: `true` if the scalar is a valid terminator, `false` otherwise.
    func isValidTerminator() -> Bool {
        if self == Token.Comma            { return true }
        if self == Token.RightBracket     { return true }
        if self == Token.RightCurly       { return true }
        if self.isWhitespace()            { return true }

        return false
    }

    //    /// Stores the `UInt8` bytes that make up the UTF8 code points for the scalar.
    //    ///
    //    /// :param: buffer the buffer to write the UTF8 code points into.
    //    func utf8(inout buffer: [UInt8]) {
    //        /*
    //         *  This implementation should probably be replaced by the function below. However,
    //         *  I am not quite sure how to properly use `SinkType` yet...
    //         *
    //         *  UTF8.encode(input: UnicodeScalar, output: &S)
    //         */
    //
    //        if value <= 0x007F {
    //            buffer.append(UInt8(value))
    //        }
    //        else if 0x0080 <= value && value <= 0x07FF {
    //            buffer.append(UInt8(value &/ 64) &+ 192)
    //            buffer.append(UInt8(value &% 64) &+ 128)
    //        }
    //        else if (0x0800 <= value && value <= 0xD7FF) || (0xE000 <= value && value <= 0xFFFF) {
    //            buffer.append(UInt8(value &/ 4096) &+ 224)
    //            buffer.append(UInt8((value &% 4096) &/ 64) &+ 128)
    //            buffer.append(UInt8(value &% 64 &+ 128))
    //        }
    //        else {
    //            buffer.append(UInt8(value &/ 262144) &+ 240)
    //            buffer.append(UInt8((value &% 262144) &/ 4096) &+ 128)
    //            buffer.append(UInt8((value &% 4096) &/ 64) &+ 128)
    //            buffer.append(UInt8(value &% 64) &+ 128)
    //        }
    //    }
}

/// The code unit value for all of the token characters used.
struct Token {
    fileprivate init() {}

    // Control Codes
    static let Linefeed         = UInt8(10)
    static let Backspace        = UInt8(8)
    static let Formfeed         = UInt8(12)
    static let CarriageReturn   = UInt8(13)
    static let HorizontalTab    = UInt8(9)

    // Tokens for JSON
    static let LeftBracket      = UInt8(91)
    static let RightBracket     = UInt8(93)
    static let LeftCurly        = UInt8(123)
    static let RightCurly       = UInt8(125)
    static let Comma            = UInt8(44)
    static let SingleQuote      = UInt8(39)
    static let DoubleQuote      = UInt8(34)
    static let Minus            = UInt8(45)
    static let Plus             = UInt8(43)
    static let Backslash        = UInt8(92)
    static let Forwardslash     = UInt8(47)
    static let Colon            = UInt8(58)
    static let Period           = UInt8(46)
    
    // Numbers
    static let Zero             = UInt8(48)
    static let One              = UInt8(49)
    static let Two              = UInt8(50)
    static let Three            = UInt8(51)
    static let Four             = UInt8(52)
    static let Five             = UInt8(53)
    static let Six              = UInt8(54)
    static let Seven            = UInt8(55)
    static let Eight            = UInt8(56)
    static let Nine             = UInt8(57)
    
    // Character tokens for JSON
    static let A                = UInt8(65)
    static let E                = UInt8(69)
    static let F                = UInt8(70)
    static let a                = UInt8(97)
    static let b                = UInt8(98)
    static let e                = UInt8(101)
    static let f                = UInt8(102)
    static let l                = UInt8(108)
    static let n                = UInt8(110)
    static let r                = UInt8(114)
    static let s                = UInt8(115)
    static let t                = UInt8(116)
    static let u                = UInt8(117)
}
