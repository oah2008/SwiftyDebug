//
//  Swizzling.swift
//  SwiftyDebug
//
//  Created by Abdulrahman Hariri on 06/03/2026.
//

import Foundation
import ObjectiveC

/// Replaces the selector's associated method implementation with the
/// given implementation (or adds it, if there was no existing one).
///
/// - Parameters:
///   - selector: The selector entry in the dispatch table.
///   - newImpl: The implementation that will be associated with the given selector.
///   - affectedClass: The class whose dispatch table will be altered.
///   - isClassMethod: Set to `true` if the selector denotes a class method, or `false` if it is an instance method.
/// - Returns: The previous implementation associated with the swizzled selector.
///            You should store the implementation and call it when overwriting the selector.
@discardableResult
func replaceMethod(_ selector: Selector, _ newImpl: IMP, _ affectedClass: AnyClass, _ isClassMethod: Bool) -> IMP {
    let foundMethod: Method?
    if isClassMethod {
        foundMethod = class_getClassMethod(affectedClass, selector)
    } else {
        foundMethod = class_getInstanceMethod(affectedClass, selector)
    }

    guard let origMethod = foundMethod else { return newImpl }

    let origImpl = method_getImplementation(origMethod)

    let targetClass: AnyClass = isClassMethod ? object_getClass(affectedClass)! : affectedClass

    if !class_addMethod(targetClass, selector, newImpl, method_getTypeEncoding(origMethod)) {
        method_setImplementation(origMethod, newImpl)
    }

    return origImpl
}
