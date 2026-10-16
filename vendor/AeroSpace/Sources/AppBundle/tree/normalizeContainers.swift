extension Workspace {
    @MainActor func normalizeContainers() {
        let preserve = rootTilingContainer.gridPreservesStructure
        rootTilingContainer.unbindEmptyAndAutoFlatten(preserveStructure: preserve) // Beware! rootTilingContainer may change after this line of code
        if !preserve && config.enableNormalizationOppositeOrientationForNestedContainers {
            rootTilingContainer.normalizeOppositeOrientationForNestedContainers()
        }
    }
}

extension TilingContainer {
    @MainActor fileprivate func unbindEmptyAndAutoFlatten(preserveStructure: Bool) {
        if let child = children.singleOrNil(), !preserveStructure && config.enableNormalizationFlattenContainers && (child is TilingContainer || !isRootContainer) {
            child.unbindFromParent()
            let mru = parent?.mostRecentChild
            let previousBinding = unbindFromParent()
            child.bind(to: previousBinding.parent, adaptiveWeight: previousBinding.adaptiveWeight, index: previousBinding.index)
            (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(preserveStructure: preserveStructure)
            if mru != self {
                mru?.markAsMostRecentChild()
            } else {
                child.markAsMostRecentChild()
            }
        } else {
            for child in children {
                (child as? TilingContainer)?.unbindEmptyAndAutoFlatten(preserveStructure: preserveStructure)
            }
            if children.isEmpty && !isRootContainer {
                unbindFromParent()
            }
        }
    }
}
