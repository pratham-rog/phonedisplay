package dev.phonedisplay.app

import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.TimeUnit

/**
 * Bounded outbound queue with one rule: a full queue may discard pointer moves
 * and control messages, but never a button-down/up. A lost button-up leaves the
 * Mac dragging forever.
 */
class InputPacketQueue(capacity: Int = 512) {
    private val queue = ArrayBlockingQueue<ByteArray>(capacity)

    fun offer(rec: ByteArray) {
        if (queue.offer(rec)) return
        if (isMovePacket(rec)) {
            if (removeFirstMove()) queue.offer(rec)
            return
        }
        if (removeFirstMove() || removeFirstNonButton()) {
            queue.offer(rec)
        }
    }

    fun poll(timeout: Long, unit: TimeUnit): ByteArray? = queue.poll(timeout, unit)

    fun clear() = queue.clear()

    private fun isMovePacket(rec: ByteArray): Boolean =
        rec.size == 15 && rec[4] == 0x04.toByte() && rec[5].toInt() == 0

    private fun isButtonPacket(rec: ByteArray): Boolean =
        rec.size == 15 && rec[4] == 0x04.toByte() &&
            (rec[5].toInt() == 1 || rec[5].toInt() == 2)

    private fun removeFirstMove(): Boolean {
        val it = queue.iterator()
        while (it.hasNext()) {
            if (isMovePacket(it.next())) {
                it.remove()
                return true
            }
        }
        return false
    }

    private fun removeFirstNonButton(): Boolean {
        val it = queue.iterator()
        while (it.hasNext()) {
            if (!isButtonPacket(it.next())) {
                it.remove()
                return true
            }
        }
        return false
    }
}
