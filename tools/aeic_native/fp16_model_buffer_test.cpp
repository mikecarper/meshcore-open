#include "modelbin.h"
#include "datareader.h"
#include "mat.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <chrono>
#include <iostream>
#include <stdexcept>
#include <string>
#include <vector>
#include <sys/resource.h>
#include <unistd.h>
static void require(bool ok,const char* reason){if(!ok)throw std::runtime_error(reason);}
struct File {FILE* fp;explicit File(const std::string& path):fp(fopen(path.c_str(),"rb")){require(fp!=nullptr,"open fixture");}~File(){fclose(fp);}};
struct Temp {std::string path;explicit Temp(const std::vector<unsigned char>& b){char name[]="/tmp/aeic-fp16-buffer-XXXXXX";int fd=mkstemp(name);require(fd>=0,"temp");path=name;size_t off=0;while(off<b.size()){auto n=write(fd,b.data()+off,b.size()-off);require(n>0,"write");off+=n;}close(fd);}~Temp(){unlink(path.c_str());}};
static std::vector<unsigned char> encoded(const std::vector<unsigned short>& values){std::vector<unsigned char> b={0x47,0x6b,0x30,0x01};auto raw=reinterpret_cast<const unsigned char*>(values.data());b.insert(b.end(),raw,raw+values.size()*2);while(b.size()%4)b.push_back(0);return b;}
static uint64_t hash(const float* values,size_t count){uint64_t h=14695981039346656037ull;auto bytes=reinterpret_cast<const unsigned char*>(values);for(size_t i=0;i<count*4;++i){h^=bytes[i];h*=1099511628211ull;}return h;}
int main(int argc,char** argv){try{
 if(argc==3){int count=std::stoi(argv[2]);require(count>0 && count<40000000,"count bound");auto start=std::chrono::steady_clock::now();ncnn::Mat weights;{File file(argv[1]);ncnn::DataReaderFromStdio dr(file.fp);ncnn::ModelBinFromDataReader mb(dr);weights=mb.load(count,0);}require(weights.w==count,"weight count");double ms=std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now()-start).count();rusage usage{};getrusage(RUSAGE_SELF,&usage);std::cout<<"{\"load_ms\":"<<ms<<",\"peak_rss_kib\":"<<usage.ru_maxrss<<",\"weights_fnv1a64\":\""<<std::hex<<hash(weights,count)<<"\"}\n";return 0;}
 size_t checked=0;for(size_t count:{size_t(1),size_t(3),size_t(65536)}){std::vector<unsigned short> half(count);for(size_t i=0;i<count;++i)half[i]=static_cast<unsigned short>(i);Temp fixture(encoded(half));ncnn::Mat values;{File file(fixture.path);ncnn::DataReaderFromStdio dr(file.fp);ncnn::ModelBinFromDataReader mb(dr);values=mb.load(count,0);}require(values.w==int(count),"stdio count");for(size_t i=0;i<count;++i){float expected=ncnn::float16_to_float32(half[i]);if(std::isfinite(expected)){require(std::memcmp(&expected,static_cast<const float*>(values)+i,4)==0,"stdio finite half bits");++checked;}}}
 for(auto bad:std::vector<std::vector<unsigned char>>{{0x47,0x6b},{0x47,0x6b,0x30,0x01,0},{0x47,0x6b,0x30,0x01,0,0,0,0,0,0}}){Temp fixture(bad);File file(fixture.path);ncnn::DataReaderFromStdio dr(file.fp);ncnn::ModelBinFromDataReader mb(dr);require(mb.load(3,0).empty(),"truncated stdio half rejects");}
 std::cout<<"{\"tests_passed\":true,\"stdio_finite_patterns_bit_exact\":"<<checked<<",\"odd_counts\":[1,3],\"truncated_cases\":3,\"weights_own_storage_after_file_close\":true}\n";return 0;
}catch(const std::exception& e){std::cerr<<e.what()<<"\n";return 1;}}
