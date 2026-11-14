#if os(iOS) && targetEnvironment(simulator)
// The simulator prototype uses the same bounded sampler as the formal viewer.
typealias WPSWindowColorSampler = WindowColorSampler
#endif
