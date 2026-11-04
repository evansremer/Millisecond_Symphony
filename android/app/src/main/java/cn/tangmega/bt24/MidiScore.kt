package cn.tangmega.bt24

import java.math.BigInteger
import java.util.ArrayDeque

data class NoteEdge(val timeUs: Long, val channel: Int, val note: Int, val velocity: Int, val on: Boolean)
data class ScoreEvent(val timeUs: Long, val word: Int)
data class PreparedScore(val events: List<ScoreEvent>, val durationUs: Long, val octave: Int,
                         val skipped: Int, val ignored: Int, val peakNotes: Int, val densityOk: Boolean)
class MidiScore private constructor(val edges: List<NoteEdge>, val durationUs: Long, val ignored: Int) {
    val bestOctave: Int get() = (listOf(0, -1, 1, -2, 2, -3, 3)).maxBy { oct ->
        edges.count { it.on && (it.channel == 9 && it.note in drums || it.channel != 9 && it.note + oct * 12 in 41..72) }
    }
    fun prepare(octave: Int): PreparedScore {
        require(octave in -3..3)
        val out = ArrayList<ScoreEvent>(); var skipped = 0; var current = 0; var peak = 0
        for (e in edges) {
            val note = if (e.channel == 9) e.note else e.note + octave * 12
            if ((e.channel == 9 && note !in drums) || (e.channel != 9 && note !in 41..72)) { if (e.on) skipped++; continue }
            val kind = if (e.on) 1 else 2
            out.add(ScoreEvent(e.timeUs, (kind shl 28) or (if (e.channel == 9) 1 shl 27 else 0) or
                (e.channel shl 19) or (note shl 12) or e.velocity))
            if (e.channel != 9) { current += if (e.on) 1 else -1; peak = maxOf(peak, current) }
        }
        // Bound the sustainable event rate and two-second prebuffer, rather than silently dropping notes.
        var start = 0; var density = true
        for (i in out.indices) {
            while (out[i].timeUs - out[start].timeUs >= 1_000_000) start++
            if (i - start + 1 > 140) density = false
        }
        return PreparedScore(out, durationUs + 100_000, octave, skipped, ignored, peak, density)
    }
    companion object {
        val drums = setOf(50,48,45,35,38,37,42,46,49,51)
        private data class Raw(val tick: Long, val order: Int, val status: Int, val a: Int, val b: Int)
        private class Reader(val b: ByteArray, var p: Int = 0, val end: Int = b.size) {
            fun byte(): Int { require(p < end) { "MIDI 数据截断" }; return b[p++].toInt() and 255 }
            fun be(n: Int): Long { var v = 0L; repeat(n) { v = (v shl 8) or byte().toLong() }; return v }
            fun tag(): String = (1..4).map { byte().toChar() }.joinToString("")
            fun vlq(): Long { var v = 0L; repeat(4) { val x = byte(); v = (v shl 7) or (x and 127).toLong(); if (x < 128) return v }; error("非法 MIDI 变长数") }
            fun skip(n: Long) { require(n >= 0 && n <= end-p) { "MIDI 长度非法" }; p += n.toInt() }
        }
        fun parse(bytes: ByteArray): MidiScore {
            require(bytes.size <= 8 * 1024 * 1024) { "文件超过 8 MiB" }
            val r = Reader(bytes); require(r.tag() == "MThd") { "请选择标准 .mid 文件" }
            val header = r.be(4); require(header >= 6 && header <= bytes.size - r.p)
            val format = r.be(2).toInt(); val tracks = r.be(2).toInt(); val ppq = r.be(2).toInt()
            require(format in 0..1) { "首版支持 MIDI Format 0/1" }
            require(tracks in 1..256 && (format != 0 || tracks == 1)) { "MIDI 轨道数非法" }
            require(ppq in 1..32767) { "首版不支持 SMPTE 时间格式" }; r.skip(header-6)
            val raw = ArrayList<Raw>(); var ignored = 0; var order = 0; var finalTick = 0L
            repeat(tracks) {
                require(r.tag() == "MTrk") { "缺少 MTrk" }; val size = r.be(4); require(size <= r.end-r.p)
                val tr = Reader(bytes, r.p, r.p+size.toInt()); r.skip(size); var tick=0L; var running=0
                while (tr.p < tr.end) {
                    tick += tr.vlq(); require(tick <= 0x7fffffffL) { "曲谱过长" }
                    val first=tr.byte(); val status=if(first<128) { require(running in 0x80..0xef); running } else first
                    if(status==255) {
                        running=0; val meta=tr.byte(); val len=tr.vlq()
                        if(meta==0x51) { require(len==3L); val tempo=tr.be(3).toInt(); require(tempo>0); raw.add(Raw(tick,order++,255,tempo,0)) }
                        else { tr.skip(len); if(meta==0x2f) { require(len==0L); break } }
                    } else if(status==0xf0 || status==0xf7) { running=0; tr.skip(tr.vlq()); ignored++ }
                    else {
                        require(status in 0x80..0xef) { "不支持的 MIDI 系统事件" }; running=status
                        val a=if(first<128)first else tr.byte(); val kind=status and 0xf0
                        val b=if(kind==0xc0 || kind==0xd0)0 else tr.byte(); require(a<128 && b<128)
                        if(kind==0x80 || kind==0x90) raw.add(Raw(tick,order++,status,a,b)) else ignored++
                    }
                    require(raw.size <= 500_000) { "曲谱事件过多" }
                }; finalTick=maxOf(finalTick,tick)
            }
            raw.sortWith(compareBy<Raw> {it.tick}.thenBy {it.order})
            var tick=0L;var us=0L;var remainder=0L;var tempo=500000L
            val timed=ArrayList<NoteEdge>()
            fun advance(to: Long) { val num=(to-tick)*tempo+remainder;us+=num/ppq;remainder=num%ppq;tick=to;require(us <= 86_400_000_000L) { "曲谱超过24小时" } }
            for(e in raw) { advance(e.tick); if(e.status==255)tempo=e.a.toLong() else timed.add(NoteEdge(us,e.status and 15,e.a,e.b,(e.status and 0xf0)==0x90 && e.b!=0)) }
            advance(finalTick)
            // Merge overlapping same-channel/same-note gates across tracks. Hardware has one raw identity.
            val counts=IntArray(16*128);val normalized=ArrayList<NoteEdge>()
            for(e in timed) {
                if(e.channel==9){if(e.on)normalized.add(e);continue}
                val id=e.channel*128+e.note
                if(e.on){if(counts[id]++==0)normalized.add(e)}
                else if(counts[id]>0 && --counts[id]==0)normalized.add(e.copy(velocity=0))
            }
            for(i in counts.indices)if(counts[i]>0)normalized.add(NoteEdge(us,i/128,i%128,0,false))
            return MidiScore(normalized,us,ignored)
        }
    }
}
