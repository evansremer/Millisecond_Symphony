package cn.tangmega.bt24

import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import kotlin.random.Random

class ScorePlayer(private val link:BleLink,private val show:(String)->Unit) {
    private val h=Handler(Looper.getMainLooper())
    private var session=0L;private var seq=0;private var score:PreparedScore?=null
    private var index=0;private var lastEvent=0L;private var cover=0L;private var eof=false
    private var status:ScoreProtocol.Status?=null;private var pending:ByteArray?=null;private var waitingSeq=0;private var sentAt=0L;private var attempts=0
    private var sending=false;private var generation=0;private var lastSeen=0L;private var active=false;private var stopping=false
    private var finishAck:(()->Unit)?=null
    val decoder=ScoreProtocol.Decoder {onStatus(it)}
    fun play(s:PreparedScore){
        require(link.ready){"请先连接 BT24"};require(s.events.isNotEmpty()){"曲谱没有可播放的音符"};require(s.densityOk){"曲谱过密，首版最多140事件/秒（兼容MTU23）"}
        require(!active){"请先停止当前曲谱"}
        generation++;active=true;stopping=false;score=s;index=0;lastEvent=0;cover=0;eof=false;status=null
        pending=null;sending=false;seq=0;session=Random.nextLong(1,0xffffffffL);lastSeen=SystemClock.elapsedRealtime()
        command(1,byteArrayOf()){};tick(generation)
    }
    fun stop(){if(!active)return;stopping=true;show("等待板端确认停止…")}
    fun disconnected(){generation++;active=false;pending=null;show("连接中断；板端将在心跳超时后止音")}
    private fun command(type:Int,payload:ByteArray,ack:()->Unit){
        if(pending!=null)return
        waitingSeq=seq;pending=ScoreProtocol.frame(type,session,seq,payload);attempts=0;finishAck=ack;transmit()
    }
    private fun transmit(){
        val frame=pending?:return;if(sending)return;sending=true;sentAt=SystemClock.elapsedRealtime();attempts++
        val token=generation
        link.send(frame){ok->if(token==generation){sending=false;if(!ok){show("BLE写入未完成，等待重试");sentAt=0}}}
    }
    private fun onStatus(s:ScoreProtocol.Status){
        if(!active || s.session!=session)return
        status=s;lastSeen=SystemClock.elapsedRealtime()
        val frame=pending
        if(frame!=null && s.expected==((waitingSeq+1) and 65535)){
            pending=null;seq=s.expected;val ack=finishAck;finishAck=null;ack?.invoke()
        }else if(frame!=null && s.expected==waitingSeq && s.reason!=0){
            show(ScoreProtocol.reason(s.reason));stopping=true
            if(s.reason==4 || s.reason==1 || s.reason==12){pending=null;seq=s.expected;finishAck=null}
        }
        if(s.state==0 || s.state==5 || s.state==4){
            if(s.state!=4){active=false;generation++;pending=null;show(ScoreProtocol.reason(s.reason));return}
        }
        if(s.state==3)show("播放 ${s.positionMs/1000}s / ${(score?.durationUs?:0)/1_000_000}s · 缓冲 ${(s.coveredUs-s.positionMs*1000).coerceAtLeast(0)/1000}ms · 最大调度迟到 ${s.lateUs}µs")
    }
    private fun tick(token:Int){
        if(token!=generation || !active)return
        val now=SystemClock.elapsedRealtime();val s=status;val music=score!!
        if(!link.ready || now-lastSeen>2500){disconnected();return}
        if(pending!=null){if(!sending && now-sentAt>350){if(attempts>=5){show("板端未确认，停止传输");disconnected();return};transmit()}}
        else if(!sending){
            if(stopping){command(4,byteArrayOf()){show("板端已接受停止")}}
            else if(s!=null){
                val target=minOf(music.durationUs,(s.positionMs*1000)+2_500_000)
                if(!eof && s.free>0 && (cover<target || index<music.events.size && music.events[index].timeUs<=cover)){
                    val from=index;var next=index;val max=minOf(20,s.free)
                    while(next<music.events.size && next-from<max && music.events[next].timeUs<=target)next++
                    val nextTime=music.events.getOrNull(next)?.timeUs
                    val newCover=if(nextTime!=null && nextTime<=target)maxOf(cover,nextTime-1,if(next>from)music.events[next-1].timeUs else 0) else target
                    val done=next==music.events.size && newCover>=music.durationUs
                    if(newCover>cover || next>from || done){
                        val bytes=ByteArray(12+(next-from)*8);ScoreProtocol.put64(bytes,0,newCover);ScoreProtocol.put32(bytes,8,if(done)1 else 0)
                        var previous=lastEvent
                        for(i in from until next){val e=music.events[i];ScoreProtocol.put32(bytes,12+(i-from)*8,e.timeUs);ScoreProtocol.put32(bytes,16+(i-from)*8,e.word.toLong());previous=e.timeUs}
                        val endIndex=next;val endEvent=previous
                        command(2,bytes){index=endIndex;lastEvent=endEvent;cover=newCover;eof=done}
                    }
                }else if(s.state==1 && (cover>=2_000_000 || eof))command(3,byteArrayOf()){show("板端已预约开始")}
                else if(now-sentAt>=250)command(5,byteArrayOf()){}
            }
        }
        h.postDelayed({tick(token)},20)
    }
}
