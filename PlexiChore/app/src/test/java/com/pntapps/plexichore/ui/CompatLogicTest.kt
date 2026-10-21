package com.pntapps.plexichore.ui

import com.pntapps.plexichore.core.DiscoveredHost
import com.pntapps.plexichore.core.Transport
import com.pntapps.plexichore.ui.navigation.adaptiveInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CompatLogicTest {
    private fun host(id: String, name: String, transport: Transport, address: String = "192.168.1.10", virtual: Boolean = true) =
        DiscoveredHost(id, name, "windows", address, 47800, transport, virtual, 0)

    @Test
    fun usbAndWifiEntriesOfTheSameComputerMergeIntoOneCardPreferringUsb() {
        val groups = HostGroup.merge(
            listOf(
                host("usb", "DESIGN-WORKSTATION", Transport.USB, "127.0.0.1"),
                host("guid-1", "design-workstation ", Transport.WIFI, "192.168.1.10", virtual = false),
                host("guid-2", "Studio-iMac", Transport.WIFI, "192.168.1.40"),
            ),
        )
        assertEquals(2, groups.size)
        val ws = groups.first()
        assertEquals(Transport.USB, ws.primary.transport)
        assertEquals(listOf(Transport.USB, Transport.WIFI), ws.transports)
        assertEquals("192.168.1.10", ws.lanAddress)
        assertTrue(ws.virtualDisplay)
        assertTrue(ws.contains(host("guid-1", "x", Transport.WIFI)))
    }

    @Test
    fun sameIdOnTwoAddressesIsOneCard() {
        val groups = HostGroup.merge(
            listOf(host("g", "PC", Transport.WIFI, "192.168.1.10"), host("g", "PC", Transport.MANUAL, "10.0.0.5")),
        )
        assertEquals(1, groups.size)
        assertEquals(Transport.WIFI, groups[0].primary.transport)
    }

    @Test
    fun unnamedUsbEntryIsNotMergedByName() {
        val groups = HostGroup.merge(listOf(host("usb", "USB", Transport.USB, "127.0.0.1"), host("g", "usb", Transport.WIFI)))
        assertEquals(2, groups.size)
        // the placeholder shown before the first USB session never merges by name either
        val placeholder = com.pntapps.plexichore.core.HostDiscovery.UNKNOWN_USB_NAME
        val groups2 = HostGroup.merge(listOf(host("usb", placeholder, Transport.USB, "127.0.0.1"), host("g", placeholder, Transport.WIFI)))
        assertEquals(2, groups2.size)
    }

    @Test
    fun twoPaneNeedsWidthAndHeight() {
        assertTrue(adaptiveInfo(1280, 800).twoPane)            // 10" / Tab S8 landscape
        assertTrue(adaptiveInfo(1024, 600).twoPane)            // 7" landscape
        assertTrue(adaptiveInfo(829, 690).twoPane)             // foldable inner screen
        assertFalse(adaptiveInfo(914, 411).twoPane)            // phone landscape: too short
        assertFalse(adaptiveInfo(800, 1280).twoPane)           // portrait
        assertFalse(adaptiveInfo(829, 690, fontScale = 2f).twoPane) // 200% text needs wider panes
        assertTrue(adaptiveInfo(914, 411).compactHeight)
        assertFalse(adaptiveInfo(1280, 800).compactHeight)
    }
}
