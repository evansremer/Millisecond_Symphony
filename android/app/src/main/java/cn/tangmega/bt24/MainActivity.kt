package cn.tangmega.bt24

import android.Manifest
import android.app.Activity
import android.app.AlertDialog
import android.bluetooth.BluetoothDevice
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import android.widget.*

class MainActivity:Activity(){
    private lateinit var link:BleLink;private lateinit var player:ScorePlayer
    private lateinit var status:TextView;private lateinit var summary:TextView;private lateinit var octave:Spinner
    private var score:MidiScore?=null;private var fileName="";private var busy=false
    override fun onCreate(state:Bundle?){super.onCreate(state);window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        val column=LinearLayout(this).apply{orientation=LinearLayout.VERTICAL;setPadding(24,24,24,24);setBackgroundColor(Color.rgb(12,18,29))}
        val scroll=ScrollView(this);scroll.addView(column);setContentView(scroll)
        fun label(text:String,size:Float=18f):TextView=TextView(this).apply{this.text=text;textSize=size;setTextColor(Color.WHITE);setPadding(0,14,0,14);column.addView(this)}
        fun button(text:String,action:()->Unit){column.addView(Button(this).apply{this.text=text;minHeight=64;setOnClickListener{try{action()}catch(e:Exception){show(e.message?:"操作失败")}}})}
        label("TANG MIDI · 蓝牙曲谱",26f)
        label("BT24 BLE → AE350 → FPGA 实时合成\n前台独奏 · 不传音频 · 不做音符量化",16f)
        status=label("尚未连接")
        link=BleLink(this,{message->show(message);if(!link.ready)player.disconnected()},{player.decoder.feed(it)})
        player=ScorePlayer(link){show(it)}
        button("扫描并连接 BT24"){permissionsThenScan()}
        button("导入 .mid 文件"){require(!busy){"正在解析文件"};startActivityForResult(Intent(Intent.ACTION_OPEN_DOCUMENT).apply{type="*/*";addCategory(Intent.CATEGORY_OPENABLE)},10)}
        summary=label("未导入曲谱")
        label("整曲八度（导入后自动选择最佳档位）",16f)
        octave=Spinner(this);octave.adapter=ArrayAdapter(this,android.R.layout.simple_spinner_dropdown_item,(-3..3).map{"${if(it>0)"+" else ""}$it 八度"});column.addView(octave)
        octave.onItemSelectedListener=object:AdapterView.OnItemSelectedListener{
            override fun onItemSelected(p:AdapterView<*>?,v:android.view.View?,i:Int,id:Long){preview()}
            override fun onNothingSelected(p:AdapterView<*>?){}
        }
        button("播放（从头开始）"){val s=score?:error("请先导入曲谱");val prepared=s.prepare(octave.selectedItemPosition-3);player.play(prepared)}
        button("停止曲谱"){player.stop()}
        button("断开蓝牙"){player.disconnected();link.close();show("已断开；板端心跳超时后释放曲谱音符")}
        label("旋律音域 MIDI 41–72；通道10走现有10鼓音。\n曲谱独奏期间，实体键盘/鼓组/激光暂停发声。\n板上 Loop 或测试运行时不能启动曲谱。\n音色选板上钢琴/圆号/合成器，八度临时为0。\n踏板、音色事件和弯音忽略；不是完整GM播放器。",15f)
    }
    private fun show(message:String){runOnUiThread{status.text=message}}
    private fun preview(){val s=score?:return;val p=s.prepare(octave.selectedItemPosition-3)
        summary.text="$fileName\n时长 ${p.durationUs/1_000_000}s · ${p.events.size}个音符事件\n跳过 ${p.skipped} 个音符 · 忽略 ${p.ignored} 个控制消息\n旋律峰值 ${p.peakNotes} 门控音符（不含释放尾音）\n合成器32声部；钢琴/圆号各16声部\n${if(p.densityOk)"事件密度可接受" else "过密：首版拒绝播放"}"}
    private fun permissionsThenScan(){
        val permissions=if(Build.VERSION.SDK_INT>=31)arrayOf(Manifest.permission.BLUETOOTH_SCAN,Manifest.permission.BLUETOOTH_CONNECT) else arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        if(permissions.any{checkSelfPermission(it)!=PackageManager.PERMISSION_GRANTED}){requestPermissions(permissions,12);return};scan()
    }
    private fun scan(){val devices=ArrayList<BluetoothDevice>();val names=ArrayList<String>();val adapter=ArrayAdapter(this,android.R.layout.simple_list_item_1,names)
        val dialog=AlertDialog.Builder(this).setTitle("选择 BT24（扫描10秒）").setAdapter(adapter){_,which->link.connect(devices[which])}.setNegativeButton("取消"){_,_->link.stopScan()}.create()
        dialog.setOnDismissListener{link.stopScan()};dialog.show();link.scan{d->devices.add(d);names.add("${d.name?:"未命名"}\n${d.address}");adapter.notifyDataSetChanged()}
    }
    override fun onRequestPermissionsResult(code:Int,permissions:Array<out String>,grants:IntArray){super.onRequestPermissionsResult(code,permissions,grants);if(code==12 && grants.isNotEmpty() && grants.all{it==PackageManager.PERMISSION_GRANTED})try{scan()}catch(e:Exception){show(e.message?:"扫描失败")}else show("需要蓝牙权限；Android 8–11还需开启系统定位")}
    @Deprecated("Activity result API without external library")
    override fun onActivityResult(request:Int,result:Int,data:Intent?){super.onActivityResult(request,result,data);if(request!=10 || result!=RESULT_OK)return;val uri=data?.data?:return
        busy=true;show("解析 MIDI…")
        Thread{
            try{val bytes=contentResolver.openInputStream(uri)!!.use{input->val out=java.io.ByteArrayOutputStream();val buffer=ByteArray(8192);while(out.size()<=8*1024*1024){val n=input.read(buffer);if(n<0)break;out.write(buffer,0,n)};out.toByteArray()};val parsed=MidiScore.parse(bytes)
                runOnUiThread{score=parsed;fileName=uri.lastPathSegment?.substringAfterLast('/')?:"MIDI";octave.setSelection(parsed.bestOctave+3);preview();show("曲谱已就绪，先确认板上音色")}}
            catch(e:Exception){show(e.message?:"文件解析失败")};busy=false
        }.start()
    }
    override fun onStop(){super.onStop();if(::player.isInitialized)player.stop()}
    override fun onDestroy(){if(::link.isInitialized){player.disconnected();link.close()};super.onDestroy()}
}
