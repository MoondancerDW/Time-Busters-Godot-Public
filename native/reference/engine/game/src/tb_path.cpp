// Own local-research implementation of the bounded original TB path contract.
// Original PE addresses document correspondence; original executable bytes are not embedded.
// Compiled only into an ignored copy of the accepted bbtime research backend.
#include "bb/game/tb_world.h"
#include <algorithm>
#include <bit>
#include <limits>

namespace bb::game {
namespace {
int32_t wi(uint32_t v) { return std::bit_cast<int32_t>(v); }
int32_t add(int32_t a,int32_t b) { return wi(uint32_t(a)+uint32_t(b)); }
int32_t sub(int32_t a,int32_t b) { return wi(uint32_t(a)-uint32_t(b)); }
int32_t mul(int32_t a,int32_t b) { return wi(uint32_t(a)*uint32_t(b)); }
int32_t neg(int32_t a) { return wi(0u-uint32_t(a)); }
int32_t shl(int32_t a,int n) { return wi(uint32_t(a)<<n); }
int32_t divz(int32_t a,int32_t b) { return a/(b?b:1); }
int32_t narrow(int32_t v) { return std::bit_cast<int16_t>(uint16_t(v)); }
V3 sn(V3 v) { return {narrow(v.x),narrow(v.y),narrow(v.z)}; }
V3 plus(V3 a,V3 b) { return {add(a.x,b.x),add(a.y,b.y),add(a.z,b.z)}; }
V3 minus(V3 a,V3 b) { return {sub(a.x,b.x),sub(a.y,b.y),sub(a.z,b.z)}; }
V3 negative(V3 a) { return {neg(a.x),neg(a.y),neg(a.z)}; }
int32_t dot(V3 a,V3 b) { return add(add(mul(a.x,b.x),mul(a.y,b.y)),mul(a.z,b.z)); }
int32_t length(V3 v) { return isqrt(dot(v,v)); }
V3 scaled(V3 v,int32_t n,int32_t d) { return {divz(mul(v.x,n),d),divz(mul(v.y,n),d),divz(mul(v.z,n),d)}; }
V3 norm(V3 v,int32_t scale=4096,bool odd=false) {
 const int32_t n=length(v);return sn(scaled(v,scale,odd?(n|1):(n?n:1)));
}
int wrap(int32_t v) { v&=4095;return v>2048?v-4096:v; }
int nativeClamp(int value,int low,int high) {if(value<low)value=low;if(value>high)value=high;return value;}
int cycle(int i,int n) { i%=n;return i<0?i+n:i; }
V3 mix(V3 a,int32_t wa,V3 b,int32_t wb,int shift) {
 return {add(mul(a.x,wa),mul(b.x,wb))>>shift,add(mul(a.y,wa),mul(b.y,wb))>>shift,add(mul(a.z,wa),mul(b.z,wb))>>shift};
}
V3 ease(V3 from,V3 to,int shift) {
 return {sub(from.x,sub(from.x,to.x)>>shift),sub(from.y,sub(from.y,to.y)>>shift),sub(from.z,sub(from.z,to.z)>>shift)};
}
// 0x450590: cubic with the central control duplicated, preserving every Q12 shift.
V3 curve(V3 a,V3 b,V3 c,int16_t t) {
 const int32_t u=narrow(4096-int32_t(t));
 const int32_t wa=mul(mul(u,u)>>12,u)>>12;
 const int32_t wb=mul(mul(mul(t,u)>>12,add(t,u)),3)>>12;
 const int32_t wc=mul(mul(t,t)>>12,t)>>12;
 return sn({add(add(mul(a.x,wa),mul(b.x,wb)),mul(c.x,wc))>>12,
            add(add(mul(a.y,wa),mul(b.y,wb)),mul(c.y,wc))>>12,
            add(add(mul(a.z,wa),mul(b.z,wb)),mul(c.z,wc))>>12});
}
// 0x43b050 and 0x43a2c0 retain the nearest vertex, then walk its two neighbours.
int nearestLocal(const std::vector<V3>& points,int index,V3 at,bool clampDistances=false) {
 const int n=int(points.size());index=cycle(index,n);
 auto distance=[&](int i){V3 d=minus(points[size_t(cycle(i,n))],at);if(clampDistances)d={std::clamp(d.x,-32768,32767),std::clamp(d.y,-32768,32767),std::clamp(d.z,-32768,32767)};return uint32_t(dot(d,d));};
 uint32_t d0=distance(index-1),d1=distance(index),d2=distance(index+1);
 // Source search terminates at a local minimum; the bounded guard handles malformed cycles explicitly.
 for(int guard=0;guard<n*2;++guard) {
  const bool previous=d0<d1;
  const bool next=d2<d1;
  if(previous) {index=cycle(index-1,n);d2=d1;d1=d0;d0=distance(index-1);}
  else if(next) {index=cycle(index+1,n);d0=d1;d1=d2;d2=distance(index+1);}
  else break;
 }
 return index;
}
}

int32_t TbWorld::pathFind(uint16_t id) const {
 for(size_t i=paths_.size();i;--i)if(paths_[i-1].id==id)return int32_t(i-1);
 return -1;
}

// 0x453f93..0x4540b9: first tick records the animation, then removes the recorder.
void TbWorld::pathRecord(TbActor& a) {
 TbTrackNode node;node.id=a.id;
 if(!a.model) {unsupported.insert("camera path recorder model missing");return;}
 uint32_t result=0;size_t calls=0;
 do {
  const Tod* before=a.anim.tod;size_t first=a.anim.next;
  result=animTick(*a.model,a.anim,calls?0:25,calls?0:2);
  if(a.anim.tod!=before)first=0;
  if(const Tod* tod=a.anim.tod)for(size_t f=first;f<a.anim.next&&f<tod->frames();++f) {
   a.attachPart=-1;
   for(uint32_t k=tod->frameStart[f];k<tod->frameStart[f+1];++k)
    if(tod->packets[k].type==0xa&&tod->packets[k].id)a.attachPart=int32_t(tod->packets[k].id)-1;
   if(a.attachPart>=0)a.attachPos=partWorld(a,a.attachPart);
  }
  if(a.attachPart>=0) {node.points.push_back(a.attachPos);a.attachPart=-1;}
  if(++calls>100000) {unsupported.insert("camera path recorder animation did not end");return;}
 }while(!(result&0x500));
 paths_.push_back(std::move(node)); // reverse lookup reproduces native head insertion, including duplicate ids
 a.f20|=0x2000;
}

// 0x43b050: closest path point/tangent for the integrated predicted position.
bool TbWorld::pathClosest(TbActor& a,V3 query,V3& tangent,V3& point) {
 if(paths_.empty()||!pathAlloc(a))return false;
 auto& cursor=a.path;
 if(cursor.fraction&0x10) {cursor.fraction=int16_t(cursor.fraction&~0x10);cursor.node=-1;}
 int32_t id=a.rec()->target;
 if(id>0&&(id&0x4000))id=S[size_t(id&~0x4000)]; // this consumer uses the unsigned S byte, unlike actorB100
 if(cursor.node<0||size_t(cursor.node)>=paths_.size()||paths_[size_t(cursor.node)].id!=uint16_t(id)) {
  cursor.node=pathFind(uint16_t(id));if(cursor.node<0)return false;
  const auto& points=paths_[size_t(cursor.node)].points;if(points.empty())return false;
  uint32_t best=UINT32_MAX;cursor.index=0;
  for(size_t i=0;i<points.size();++i) {
   V3 delta=minus(points[i],a.pos);
   // Native 0x4030e0 SQR clamps each component to signed16 before squaring.
   delta={std::clamp(delta.x,-32768,32767),std::clamp(delta.y,-32768,32767),std::clamp(delta.z,-32768,32767)};
   const uint32_t d=uint32_t(dot(delta,delta));if(d<best)best=d,cursor.index=int16_t(i);
  }
 }
 const auto& points=paths_[size_t(cursor.node)].points;const int n=int(points.size());if(n<1)return false;
 cursor.index=int16_t(nearestLocal(points,cursor.index,query,true));
 const V3 center=points[size_t(cursor.index)];
 const V3 v=minus(query,center),left=minus(points[size_t(cycle(cursor.index-1,n))],center),right=minus(points[size_t(cycle(cursor.index+1,n))],center);
 auto project=[&](V3 edge,int32_t& amount,V3& unit,int32_t& reducedDenominator) {
  amount=dot(v,edge);int32_t d=dot(edge,edge);const int32_t original=d;
  while(amount>32000||amount< -32000) {amount>>=1;d>>=1;}
  reducedDenominator=d?d:1;V3 p=sn(scaled(edge,amount,reducedDenominator));
  unit=sn(scaled(edge,4096,isqrt(original)?isqrt(original):1));return p;
 };
 int32_t dl,dr,denL,denR;V3 ul,ur;
 const V3 pl=project(left,dl,ul,denL),pr=project(right,dr,ur,denR);V3 offset;
 if(dl<0&&dr<0) {
  const int32_t l=length(pl),r=length(pr),total=add(l,r);const int32_t t=total?divz(shl(l,12),total):4096;
  offset={};tangent=sn(mix(ul,sub(t,4096),ur,t,12));
 } else if(dl>=0&&dr>=0) {
  const int32_t d=dl?dl:1;int32_t square=dot(pl,pl);const int32_t total=add(square,dot(pr,pr));
  int32_t t=denR;if(total>0)t=divz(shl(square,12),total);
  tangent=sn(mix(ur,sub(4096,t),ul,neg(t),12));
  if(total>0)square=divz(mul(square,add(dr,d)),total);
  offset=square<d?sn(scaled(pl,sub(d,square),d)):sn(scaled(pr,sub(square,d),d));
 } else if(dl>=0) {offset=pl;tangent=sn(ul);}
 else {offset=pr;tangent=sn(ur);}
 point=sn(plus(center,offset));return true;
}

// 0x43b870: constrain an already world-space request; update orientation for the next tick.
void TbWorld::pathConstrain(TbActor& a,std::array<int32_t,3>& request,uint16_t radius) {
 V3 predicted=sn(plus(a.pos,{request[0],request[1],request[2]})),direction,point;
 if(!pathClosest(a,predicted,direction,point))return;
 const V3 off=sn(minus(predicted,point));const int32_t side=a.rec()->side;
 auto limit=[&](int32_t distance) {
  const int32_t half=radius>>1;
  if(distance>radius)return int32_t(0);
  if(distance>half)return mul(side,add(divz(shl(sub(half,distance),12),half),4096))>>12;
  return side;
 };
 const int32_t square=add(mul(off.x,off.x),mul(off.z,off.z));int32_t turn=side;
 if(square>(mul(radius,radius)>>2)) {
  const int32_t distance=isqrt(square);turn=limit(distance);
  if(distance>radius) {predicted.x=narrow(add(point.x,divz(mul(off.x,radius),distance)));predicted.z=narrow(add(point.z,divz(mul(off.z,radius),distance)));}
 }
 const V3 forward=apply16(coordMat(&a,-1),{0,0,4096});
 if(dot(direction,forward)<0)direction=sn(negative(direction));
 int32_t yaw=ratan2(direction.x,direction.z);
 if(a.rec()->flagsC&0x200) {
  const bool positive=wrap(sub(ratan2(off.x,off.z),yaw))>0;
  const int32_t low=narrow(positive?neg(side):neg(turn)),high=narrow(positive?turn:side);
  yaw=add(yaw,nativeClamp(wrap(sub(a.yaw,yaw)),low,high))&4095;
 }
 a.yaw=int16_t(yaw);
 if(a.rec()->flagsC&0x400) {
  const int32_t vertical=std::abs(off.y);turn=limit(vertical);
  if(vertical>radius)predicted.y=narrow(add(point.y,off.y>0?radius:-int32_t(radius)));
  int32_t pitch=neg(ratan2(direction.y,isqrt(add(mul(direction.x,direction.x),mul(direction.z,direction.z)))));
  if(a.rec()->flagsC&0x200) {
   const int32_t low=narrow(off.y<0?neg(side):neg(turn)),high=narrow(off.y<0?turn:side);
   pitch=add(pitch,nativeClamp(wrap(sub(a.pitch,pitch)),low,high))&4095;
  }
  a.pitch=int16_t(pitch);
 }
 const V3 moved=sn(minus(predicted,a.pos));request={moved.x,moved.y,moved.z};
}

// 0x455f0a..0x45625a: the distinct stateB100 consumer advances a cubic-control cursor.
bool TbWorld::pathActorFollow(TbActor& a) {
 if(!pathAlloc(a))return false;
 if(paths_.empty())return true;
 auto& cursor=a.path;const auto* r=a.rec();
 auto value=[&](int16_t v) {return v>0&&(v&0x6000)?int32_t(int8_t(S[size_t(uint16_t(v)&~0x6000)])):int32_t(v);};
 if(cursor.node<0) {
  cursor.node=pathFind(uint16_t(value(r->target)));if(cursor.node<0)return true;
  const int n=int(paths_[size_t(cursor.node)].points.size());if(n<3)return true;
  cursor.index=int16_t(cycle(value(r->side)+2,n));cursor.control=paths_[size_t(cursor.node)].points[size_t(cycle(cursor.index-2,n))];
  cursor.point=a.pos;cursor.fraction=0x80;
 }
 const auto& points=paths_[size_t(cursor.node)].points;const int n=int(points.size());if(n<3)return true;
 const int32_t radius=(r->cap>0&&(r->cap&0x6000))?shl(value(r->cap),4):r->cap;int relative=0,heading=0;
 for(int guard=0;guard<n*32;++guard) {
  const V3 d=minus(cursor.point,a.pos);const int32_t square=add(mul(d.x,d.x),mul(d.z,d.z));
  const uint32_t magnitude=uint32_t(square<0?neg(square):square);
  if(magnitude<=uint32_t(mul(radius,radius))||(relative>0x400&&relative<0xc00)) {
   cursor.fraction=int16_t(cursor.fraction+0x80);
   if(uint16_t(cursor.fraction)>0x800) {cursor.fraction=0x80;cursor.index=int16_t(cycle(cursor.index+1,n));cursor.control=points[size_t(cycle(cursor.index-2,n))];}
  }
  cursor.point=curve(cursor.control,points[size_t(cycle(cursor.index-1,n))],points[size_t(cycle(cursor.index,n))],uint16_t(cursor.fraction));
  const V3 to=minus(cursor.point,a.pos),back=minus(cursor.control,a.pos);
  heading=ratan2(to.x,to.z);relative=(ratan2(back.x,back.z)-heading)&4095;
  if(relative<=0x400||relative>=0xc00)break;
  if(guard==n*32-1)unsupported.insert("actor path cursor did not converge");
 }
 a.yaw=int16_t(heading);
 // Original 0x456234..0x456253 passes (deltaZ, deltaY), deliberately retained.
 if(r->flagsC&0x40)a.pitch=int16_t(ratan2(sub(cursor.point.z,a.pos.z),sub(cursor.point.y,a.pos.y))&4095);
 return true;
}

// Native option setters: current values snap unless their corresponding smoothing bit is set.
void TbWorld::cameraPathMode(uint32_t mode) {camPath.modes=mode|((mode&0x200)?0x400:0);}
void TbWorld::cameraPathDistance(int32_t distance) {camPath.distanceTarget=distance;if(!(camPath.modes&0x80))camPath.distance=distance;}
void TbWorld::cameraPathHeight(int32_t height) {camPath.heightTarget=height;if(!(camPath.modes&0x100))camPath.height=height;}
void TbWorld::cameraPathTarget(const TbActor* actor) {
 camPath.targetUid=int32_t((actor?actor:&player(focus()))->uid);camPath.modes|=0x40;
}
void TbWorld::cameraPathClear() {camPath.node=-1;cam.pathId=0;}
bool TbWorld::cameraPathSelect(uint16_t id,int32_t distance) {
 const int32_t node=pathFind(id);if(node<0)return false;
 const auto& points=paths_[size_t(node)].points;if(points.size()<2)return false;
 camPath.node=node;cameraPathDistance(distance);camPath.modes&=~0x40u;
 camPath.targetUid=int32_t(player(focus()).uid);
 const V3 at=player(focus()).pos;int32_t best=INT32_MAX;int index=0;bool found=false;
 for(size_t i=0;i+1<points.size();++i) {const V3 d=minus(at,points[i]);const int32_t square=dot(d,d);if(square>=0&&square<best)best=square,index=int(i),found=true;}
 if(!found) {cameraPathClear();unsupported.insert("camera path has no defined initial vertex");return false;}
 camPath.index=index;cam.pathId=id;return true;
}

// 0x43a2c0: nearest-vertex local projection, arc-distance eye placement, native mode smoothing.
void TbWorld::cameraPathFollow(const TbActor& focusActor) {
 if(paths_.empty()||camPath.node<0||size_t(camPath.node)>=paths_.size())return;
 if((camPath.modes&0x200)&&!(camPath.modes&0x400)) {cameraPathClear();return;}
 camPath.modes&=~0x400u;const TbActor* actor=&focusActor;
 if(camPath.modes&0x40) {const TbActor* selected=entity(camPath.targetUid);if(selected)actor=selected;}
 const auto& points=paths_[size_t(camPath.node)].points;const int n=int(points.size());if(n<2)return;
 cam.pathId=paths_[size_t(camPath.node)].id;cam.body=cam.prevBody;cam.look=cam.prevLook;cam.eye=cam.prevEye;
 camPath.index=nearestLocal(points,camPath.index,actor->pos);
 const int previous=cycle(camPath.index-1,n),next=cycle(camPath.index+1,n);
 const V3 central=norm(minus(points[size_t(previous)],points[size_t(next)]));
 const int32_t primary=dot(minus(points[size_t(camPath.index)],actor->pos),central)>>12;
 int headingA=ratan2(neg(central.x),neg(central.z)),headingB=headingA;int anchor;int32_t factor,along;
 V3 projected;
 if(primary<0) {
  const V3 adjacent=norm(minus(points[size_t(camPath.index)],points[size_t(cycle(previous-1,n))]),4096,true);
  int32_t secondary=dot(minus(points[size_t(previous)],actor->pos),adjacent)>>12;if(secondary<0)secondary=neg(secondary);
  headingB=headingA;headingA=ratan2(adjacent.x,adjacent.z);
  const V3 segment=minus(points[size_t(camPath.index)],points[size_t(previous)]);const int32_t span=length(segment)|1;
  const V3 unit=norm(segment,16384,true);
  factor=divz(shl(secondary,12),add(neg(primary),secondary));along=mul(factor,span)>>12;
  projected=plus(points[size_t(previous)],{mul(along,unit.x)>>14,mul(along,unit.y)>>14,mul(along,unit.z)>>14});anchor=previous;
 }else {
  const V3 adjacent=norm(minus(points[size_t(cycle(next+1,n))],points[size_t(camPath.index)]),4096,true);
  int32_t secondary=dot(minus(points[size_t(next)],actor->pos),adjacent)>>12;if(secondary<0)secondary=neg(secondary);
  headingB=ratan2(adjacent.x,adjacent.z);
  const V3 segment=minus(points[size_t(next)],points[size_t(camPath.index)]);const int32_t span=length(segment)|1;
  const V3 unit=norm(segment,16384,true);
  factor=primary>0?divz(shl(primary,12),add(secondary,primary)):0;along=mul(factor,span)>>12;
  projected=plus(points[size_t(camPath.index)],{mul(along,unit.x)>>14,mul(along,unit.y)>>14,mul(along,unit.z)>>14});anchor=camPath.index;
 }
 int first=anchor,second=cycle(anchor+1,n);int32_t consumed=0,segmentLength=0;
 const int32_t desired=add(camPath.distance,along);bool located=false;
 if(camPath.distance<0) {
  for(int guard=0;consumed>desired&&guard<n*4;++guard) {first=cycle(first-1,n);second=cycle(second-1,n);segmentLength=length(minus(points[size_t(second)],points[size_t(first)]));consumed=sub(consumed,segmentLength);located=true;}
  segmentLength=add(segmentLength,sub(desired,consumed));
 }else {
  for(int guard=0;guard<n*4;++guard) {const int32_t span=length(minus(points[size_t(second)],points[size_t(first)]));consumed=add(consumed,span);segmentLength=span;if(consumed>=desired) {located=true;break;}first=second;second=cycle(second+1,n);}
  segmentLength=add(segmentLength,sub(desired,consumed));
 }
 const V3 segment=minus(points[size_t(second)],points[size_t(first)]);const int32_t span=length(segment);
 if(!span||(!located&&camPath.distance>=0)) {unsupported.insert("camera path arc is degenerate");return;}
 const V3 unit=sn(scaled(segment,4096,span));
 const V3 walked=plus(points[size_t(first)],{mul(segmentLength,unit.x)>>12,mul(segmentLength,unit.y)>>12,mul(segmentLength,unit.z)>>12});
 const uint32_t mode=camPath.modes;
 if(mode&0x21) {
  cam.look.x=sub(cam.look.x,sub(cam.look.x,actor->pos.x)>>1);cam.look.z=sub(cam.look.z,sub(cam.look.z,actor->pos.z)>>1);
  if(!(mode&0x20)) {const int32_t error=add(sub(cam.look.y,actor->pos.y),(mode&0x10)?camPath.height:0);cam.look.y=sub(cam.look.y,error>>2);}
  else if(mode&0x10)cam.look.y=sub(cam.look.y,add(sub(cam.look.y,walked.y),camPath.height)>>2);
  else cam.eye.y=sub(cam.eye.y,sub(cam.eye.y,projected.y)>>2);
  cam.eye=ease(cam.eye,(mode&12)?projected:walked,2);
 }else if(!(mode&12)) {
  cam.look=ease(cam.look,plus(projected,{0,camPath.height,0}),1);cam.eye=ease(cam.eye,walked,2);
 }else {
  int32_t angle=add(headingA,mul(factor,wrap(sub(headingB,headingA)))>>12)-0x400;if(mode&8)angle-=0x800;
  const V3 desiredLook=plus(projected,{mul(camPath.distance,rsin(angle))>>12,camPath.height,mul(camPath.distance,rcos(angle))>>12});
  cam.look=ease(cam.look,desiredLook,2);cam.eye=ease(cam.eye,projected,2);
 }
 cam.body=cam.eye;cam.prevBody=cam.body;cam.prevLook=cam.look;cam.prevEye=cam.eye;
 auto approach=[](int32_t value,int32_t target) {const int32_t d=sub(value,target);return d>10?sub(value,10):d< -10?add(value,10):target;};
 camPath.distance=approach(camPath.distance,camPath.distanceTarget);camPath.height=approach(camPath.height,camPath.heightTarget);
}

} // namespace bb::game
