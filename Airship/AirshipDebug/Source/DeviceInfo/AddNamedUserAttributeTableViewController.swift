/* Copyright Airship and Contributors */

#if canImport(AirshipCore)
import AirshipCore
#elseif canImport(Airship)
import Airship
#endif

class AddNamedUserAttributeTableViewController: AddAttributeTableViewController {

    override internal func applyMutations(_ mutations : UAAttributeMutations) {
        UAirship.namedUser().apply(mutations)
    }
}
