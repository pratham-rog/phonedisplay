package dev.phonedisplay.app

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.concurrent.TimeUnit

class InputPacketQueueTest {
    private fun input(kind: Int, x: Int = 0): ByteArray = ByteArray(15).also { rec ->
        rec[3] = 10
        rec[4] = 0x04
        rec[5] = kind.toByte()
        rec[7] = (x ushr 24).toByte()
        rec[8] = ((x ushr 16) and 0xFF).toByte()
        rec[9] = ((x ushr 8) and 0xFF).toByte()
        rec[10] = (x and 0xFF).toByte()
    }

    private fun control(type: String): ByteArray {
        val payload = """{"type":"$type"}""".toByteArray()
        return ByteArray(5 + payload.size).also { rec ->
            rec[3] = payload.size.toByte()
            rec[4] = 0x04
            payload.copyInto(rec, 5)
        }
    }

    private fun drain(queue: InputPacketQueue): List<ByteArray> = buildList {
        while (true) add(queue.poll(0, TimeUnit.MILLISECONDS) ?: break)
    }

    private fun x(rec: ByteArray): Int =
        ((rec[7].toInt() and 0xFF) shl 24) or
            ((rec[8].toInt() and 0xFF) shl 16) or
            ((rec[9].toInt() and 0xFF) shl 8) or
            (rec[10].toInt() and 0xFF)

    @Test
    fun buttonUpSurvivesFullQueueOfMoves() {
        val queue = InputPacketQueue(4)
        repeat(4) { queue.offer(input(0, it)) }

        queue.offer(input(2, 99))

        val sent = drain(queue)
        assertEquals(4, sent.size)
        assertTrue(sent.any { it[5].toInt() == 2 && x(it) == 99 })
        assertFalse(sent.any { it[5].toInt() == 0 && x(it) == 0 })
    }

    @Test
    fun buttonUpSurvivesFullQueueOfControls() {
        val queue = InputPacketQueue(4)
        repeat(2) { queue.offer(control("heartbeat")) }
        repeat(2) { queue.offer(input(1, it)) }

        queue.offer(input(2, 99))

        val sent = drain(queue)
        assertEquals(4, sent.size)
        assertEquals(2, sent.count { it[5].toInt() == 1 })
        assertTrue(sent.any { it[5].toInt() == 2 && x(it) == 99 })
    }

    @Test
    fun movesKeepTheNewestAndDropTheOldest() {
        val queue = InputPacketQueue(4)
        repeat(4) { queue.offer(input(0, it)) }

        queue.offer(input(0, 4))

        val sent = drain(queue)
        assertEquals(listOf(1, 2, 3, 4), sent.map { x(it) })
    }
}
