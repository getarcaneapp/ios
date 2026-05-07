//
//  Item.swift
//  Arcane Mobile
//
//  Created by Kyle Mendell on 5/6/26.
//

import Foundation
import SwiftData

@Model
final class Item {
    var timestamp: Date
    
    init(timestamp: Date) {
        self.timestamp = timestamp
    }
}
