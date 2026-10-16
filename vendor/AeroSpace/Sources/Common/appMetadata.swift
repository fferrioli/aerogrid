public let stableAeroSpaceAppId: String = "local.AeroGrid.Backend"
#if DEBUG
    public let aeroSpaceAppId: String = "local.AeroGrid.Backend.debug"
    public let aeroSpaceAppName: String = "AeroSpace-Debug"
#else
    public let aeroSpaceAppId: String = stableAeroSpaceAppId
    public let aeroSpaceAppName: String = "AeroSpace"
#endif
