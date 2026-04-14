# Suppress duplicate unit-address warnings from nRF52840 DTS
list(APPEND EXTRA_DTC_FLAGS "-Wno-unique_unit_address_if_enabled")
