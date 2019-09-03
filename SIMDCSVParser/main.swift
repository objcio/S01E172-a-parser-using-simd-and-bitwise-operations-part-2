//
//  main.swift
//  SIMDCSVParser
//
//  Created by Chris Eidhof on 22.08.19.
//  Copyright © 2019 Chris Eidhof. All rights reserved.
//

import Foundation

extension String {
    var key: String {
        return padding(toLength: 20, withPad: " ", startingAt: 0)
    }
}

extension UInt64 {
    func indices(offset: Int) -> [Int] {
        return Array(self).enumerated().filter { $0.element }.map { $0.offset + offset } // todo: too many allocations
    }
}

extension Data {
    func parseCSV() -> [[Range<Int>]] {
        assert(count >= 64)
        return withUnsafeBytes { buf in
            var inQuotes = false
            var commas: [Int] = []
            var newlines: [Int] = []
            for chunkStart in stride(from: 0, to: count, by: 64) {
                let chunkEnd = chunkStart + 64
                guard chunkEnd <= count else { print("TODO final chunk"); continue }
                let chunk = UnsafeRawBufferPointer(rebasing: buf[chunkStart..<chunkEnd])
                let (commaMask, newlineMask) = chunk.parseCSVChunk(inQuotes: &inQuotes)
                let commaIndices = commaMask.indices(offset: chunkStart)
                let newlineIndices = newlineMask.indices(offset: chunkStart)
                commas.append(contentsOf: commaIndices)
                newlines.append(contentsOf: newlineIndices)
            }
            var result: [[Range<Int>]] = []
            var currentLine: [Range<Int>] = []
            var previousOffset = 0
            for comma in commas {
                while let n = newlines.first, comma > n {
                    newlines.removeFirst() // todo inefficient
                    currentLine.append(previousOffset..<n)
                    result.append(currentLine)
                    currentLine = []
                    previousOffset = n + 1
                }
                currentLine.append(previousOffset..<comma)
                previousOffset = comma + 1
            }
            currentLine.append(previousOffset..<count)
            result.append(currentLine)
            return result
        }
    }
}

extension UInt8 {
    static let quote: UInt8 = "\"".utf8.first!
    static let comma: UInt8 = ",".utf8.first!
    static let newline: UInt8 = "\n".utf8.first!
}

extension UInt64 {
    static let evens: UInt64 = (0..<64).reduce(0, { result, bit in
        (bit % 2 == 0) ? result | (1 << bit) : result
    })
    static let odds = ~evens
}

extension UnsafeRawBufferPointer {
    func parseCSVChunk(inQuotes: inout Bool) -> (commas: UInt64, newlines: UInt64) {
        assert(count == 64)
        let input = self.baseAddress!.assumingMemoryBound(to: UInt8.self)
        let quotes = cmp_mask_against_input(input, .quote)
        
        let quoteStarts = ~(quotes << 1) & quotes
        let evenStarts = quoteStarts & .evens
        var endsOfEvenStarts = evenStarts &+ quotes
        endsOfEvenStarts &= ~quotes
        let oddEndsOfEvenStarts = endsOfEvenStarts & .odds
        
        let oddStarts = quoteStarts & .odds
        var (endsOfOddStarts, overflow) = oddStarts.addingReportingOverflow(quotes)
        endsOfOddStarts &= ~quotes
        let evenEndsOfOddStarts = endsOfOddStarts & .evens
        let endsOfOddLength = oddEndsOfEvenStarts | evenEndsOfOddStarts
        
        var stringMask = carryless_multiply(endsOfOddLength, ~0)
        if inQuotes {
            stringMask = ~stringMask
        }
        
        let commas = cmp_mask_against_input(input, .comma)
        let newlines = cmp_mask_against_input(input, .newline)
        let controlCommas = commas & ~stringMask
        let controlNewlines = newlines & ~stringMask

        inQuotes = stringMask[63] && !overflow || !stringMask[63] && overflow
        
        return (controlCommas, controlNewlines)
    }
}

extension UInt64: Collection {
    public var startIndex: Int { 0 }
    public var endIndex: Int { 64 }
    public func index(after i: Int) -> Int {
        return i + 1
    }
    public subscript(index: Int) -> Bool {
        return (self & (1 << index)) > 0
    }
    
    var bits: String {
        map { $0 ? "1" : "0" }.joined(separator: "")
    }
}

let sample = #"""
"Plain Field","Field,with comma","With """"escaped"" quotes","Another field",without quotes
"Plain Field","Field,with comma","With """"escaped"" quotes","Another field",without quotes
"""#

let sample1 = #"""
"Plain Field","Field,with comma","With """"escaped"" quotes    ","Another field","Plain Field","Field,with comma","With """"escaped"" quotes","Another field"
"""#

let sample2 = #"""
"Plain Field","Field,with comma","With """"escaped"" quotes  ","Another field","Plain Field","Field,with comma","With """"escaped"" quotes","Another field"
"""#

let data = sample2.data(using: .utf8)!
print("CSV".key, sample.prefix(64))
let lines = data.parseCSV()
dump(lines.map { line in
    line.map { range in
        String(data: data[range], encoding: .utf8)!
    }
})
