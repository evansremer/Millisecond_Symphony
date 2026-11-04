package cn.tangmega.bt24

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.Context
import android.os.Handler
import android.os.Looper
import java.util.UUID

@SuppressLint("MissingPermission")
class BleLink(private val context:Context,private val changed:(String)->Unit,private val received:(ByteArray)->Unit) {
    private val handler=Handler(Looper.getMainLooper())
    private val adapter=(context.getSystemService(Context.BLUETOOTH_SERVICE) as BluetoothManager).adapter
    private var gatt:BluetoothGatt?=null
    private var writeChar:BluetoothGattCharacteristic?=null
    private var notifyChar:BluetoothGattCharacteristic?=null
    private var callback:ScanCallback?=null
    private var epoch=0;private var busy=false;private var mtu=23;var ready=false;private set
    private fun uuid(n:Int)=UUID.fromString("0000%04x-0000-1000-8000-00805f9b34fb".format(n))
    fun scan(found:(BluetoothDevice)->Unit) {
        require(adapter!=null && adapter.isEnabled){"请先打开蓝牙"};stopScan()
        val seen=mutableSetOf<String>()
        callback=object:ScanCallback(){override fun onScanResult(type:Int,result:ScanResult){if(seen.add(result.device.address))handler.post{found(result.device)}}}
        adapter.bluetoothLeScanner.startScan(callback)
        handler.postDelayed({stopScan()},10000)
    }
    fun stopScan(){callback?.let{adapter?.bluetoothLeScanner?.stopScan(it)};callback=null}
    fun connect(device:BluetoothDevice){close();changed("连接 ${device.name?:device.address}");gatt=device.connectGatt(context,false,cb,BluetoothDevice.TRANSPORT_LE)}
    fun close(){epoch++;busy=false;ready=false;mtu=23;writeChar=null;notifyChar=null;stopScan();gatt?.disconnect();gatt?.close();gatt=null}
    private fun fail(message:String){close();changed(message)}
    private val cb=object:BluetoothGattCallback(){
        override fun onConnectionStateChange(g:BluetoothGatt,status:Int,newState:Int){handler.post{
            if(g!==gatt)return@post
            if(status!=BluetoothGatt.GATT_SUCCESS || newState==BluetoothProfile.STATE_DISCONNECTED){fail("蓝牙已断开 ($status)");return@post}
            if(newState==BluetoothProfile.STATE_CONNECTED){changed("发现 BLE 服务…");g.requestConnectionPriority(BluetoothGatt.CONNECTION_PRIORITY_HIGH);g.discoverServices()}
        }}
        override fun onServicesDiscovered(g:BluetoothGatt,status:Int){handler.post{
            if(g!==gatt)return@post
            val s=g.getService(uuid(0xffe0));val w=s?.getCharacteristic(uuid(0xffe2));val n=s?.getCharacteristic(uuid(0xffe1))
            if(status!=0 || w==null || n==null || w.properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE==0 || n.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY==0){fail("BT24 透传服务/特征不匹配");return@post}
            writeChar=w;notifyChar=n
            if(!g.requestMtu(247))enableNotify(g)
        }}
        override fun onMtuChanged(g:BluetoothGatt,value:Int,status:Int){handler.post{if(g===gatt){mtu=if(status==0)value else 23;enableNotify(g)}}}
        override fun onDescriptorWrite(g:BluetoothGatt,d:BluetoothGattDescriptor,status:Int){handler.post{
            if(g!==gatt)return@post
            if(status!=0){fail("无法启用板端通知");return@post};ready=true;changed("已连接，MTU $mtu")
        }}
        @Deprecated("Legacy callback required for Android 8–12")
        override fun onCharacteristicChanged(g:BluetoothGatt,c:BluetoothGattCharacteristic){val bytes=c.value?.clone()?:return;handler.post{if(g===gatt)received(bytes)}}
        override fun onCharacteristicChanged(g:BluetoothGatt,c:BluetoothGattCharacteristic,value:ByteArray){val bytes=value.clone();handler.post{if(g===gatt)received(bytes)}}
    }
    private fun enableNotify(g:BluetoothGatt){
        val c=notifyChar?:return;val d=c.getDescriptor(uuid(0x2902))
        if(d==null || !g.setCharacteristicNotification(c,true)){fail("缺少通知描述符");return}
        d.value=BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        if(!g.writeDescriptor(d))fail("通知订阅提交失败")
    }
    fun send(frame:ByteArray,done:(Boolean)->Unit){
        if(!ready || busy){done(false);return};busy=true;val token=epoch;var offset=0
        fun chunk(){
            if(token!=epoch){done(false);return}
            val g=gatt;val c=writeChar
            if(g==null || c==null || !ready){busy=false;done(false);return}
            val length=minOf(mtu-3,180,frame.size-offset);c.writeType=BluetoothGattCharacteristic.WRITE_TYPE_NO_RESPONSE;c.value=frame.copyOfRange(offset,offset+length)
            if(!g.writeCharacteristic(c)){busy=false;done(false);return}
            offset+=length
            if(offset==frame.size){handler.postDelayed({if(token==epoch){busy=false;done(true)}else done(false)},20)}
            else handler.postDelayed({chunk()},8)
        };chunk()
    }
}
