package cn.tangmega.bt24

object ScoreProtocol {
    fun u16(b: ByteArray,p:Int)=(b[p].toInt() and 255) or ((b[p+1].toInt() and 255) shl 8)
    fun u32(b: ByteArray,p:Int)=u16(b,p).toLong() or (u16(b,p+2).toLong() shl 16)
    fun put16(b:ByteArray,p:Int,v:Int){b[p]=v.toByte();b[p+1]=(v ushr 8).toByte()}
    fun put32(b:ByteArray,p:Int,v:Long){put16(b,p,v.toInt());put16(b,p+2,(v ushr 16).toInt())}
    fun put64(b:ByteArray,p:Int,v:Long){put32(b,p,v);put32(b,p+4,v ushr 32)}
    fun crc(b:ByteArray,n:Int):Int {var c=65535;for(i in 0 until n){c=c xor ((b[i].toInt() and 255) shl 8);repeat(8){c=if(c and 32768!=0)(c shl 1) xor 0x1021 else c shl 1}};return c and 65535}
    fun frame(type:Int,session:Long,sequence:Int,payload:ByteArray=byteArrayOf()):ByteArray {
        require(payload.size<=192);val b=ByteArray(payload.size+14);b[0]=66;b[1]=84;b[2]=1;b[3]=type.toByte()
        put32(b,4,session);put16(b,8,sequence);put16(b,10,payload.size);payload.copyInto(b,12);put16(b,b.size-2,crc(b,b.size-2));return b
    }
    data class Status(val session:Long,val state:Int,val reason:Int,val expected:Int,val free:Int,val positionMs:Long,val coveredUs:Long,val sent:Long,val lateUs:Long)
    class Decoder(val receive:(Status)->Unit) {
        private val b=ByteArray(206);private var n=0;private var total=0
        fun feed(bytes:ByteArray){for(x in bytes){
            if(n==0){if(x.toInt()==66)b[n++]=x;continue}
            if(n==1 && x.toInt()!=84){n=if(x.toInt()==66)1 else 0;continue}
            b[n++]=x
            if(n==12){val size=u16(b,10);if(size>192){n=0;continue};total=size+14}
            if(n>=12 && n==total){
                if(b[2].toInt()==1 && (b[3].toInt() and 255)==128 && total==74 && crc(b,72)==u16(b,72))
                    receive(Status(u32(b,4),u32(b,12).toInt(),u32(b,16).toInt(),u32(b,20).toInt(),u32(b,24).toInt(),u32(b,28),u32(b,32) or (u32(b,36) shl 32),u32(b,40),u32(b,52)))
                n=0
            }
        }}
    }
    fun reason(code:Int)=listOf("正常","数据帧错误","序号错误","缓冲已满","Loop/测试或止音正在运行","曲谱缓冲欠载","心跳超时","串口错误","音频队列错误","全局止音","已停止","播放结束","预缓冲不足").getOrElse(code){"错误 $code"}
}
