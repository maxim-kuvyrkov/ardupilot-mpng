/*
	APM_ADC.cpp - ADC ADS7844 Library for Ardupilot Mega
Total rewrite by Syberian:

Full I2C sensors replacement:
ITG3200, BMA180

Integrated analog Sonar on the ADC channel 7 (in centimeters)
//D10 (PORTL.1) = input from sonar
//D9 (PORTL.2) = sonar Tx (trigger)
//The smaller altitude then lower the cycle time

	
	
	
*/
extern "C" {
  // AVR LibC Includes
  #include <inttypes.h>
  #include <avr/interrupt.h>
  #include "WConstants.h"
}

#include "AP_ADC_ADS7844.h"

static volatile uint16_t 		_filter[8][ADC_FILTER_SIZE];
static volatile uint8_t			_filter_index;


//*****************************
// Select your IMU board type:
// #define FFIMU
#define ALLINONE
// #define BMA_020 // do you have it?

//*******************************
// Select sonar type
// #define DYPME007
 #define DYPME007v2
// #define SONARDEBUG
//*******************************
// sonar filter
#define SONARFILTER
#define SONAR_FILTER_SIZE 4




// *********************
// I2C general functions
// *********************
  #define I2C_PULLUPS_DISABLE        PORTC &= ~(1<<4); PORTC &= ~(1<<5);
#ifdef ALLINONE
#define BMA180_A 0x82
#else
#define BMA180_A 0x80
#endif

#ifdef BMA_020
#define ACC_DIV 33.49
#else
#define ACC_DIV 28
#endif



// Mask prescaler bits : only 5 bits of TWSR defines the status of each I2C request
#define TW_STATUS_MASK	(1<<TWS7) | (1<<TWS6) | (1<<TWS5) | (1<<TWS4) | (1<<TWS3)
#define TW_STATUS       (TWSR & TW_STATUS_MASK)
int neutralizeTime;


void i2c_init(void) {
    I2C_PULLUPS_DISABLE
  TWSR = 0;        // no prescaler => prescaler = 1
  TWBR = ((16000000L / 400000L) - 16) / 2; // change the I2C clock rate
  TWCR = 1<<TWEN;  // enable twi module, no interrupt
}
void waitTransmissionI2C() {
  uint8_t count = 255;
  while (count-->0 && !(TWCR & (1<<TWINT)) );
  if (count<2) { //we are in a blocking state => we don't insist
    TWCR = 0;  //and we force a reset on TWINT register
    neutralizeTime = micros(); //we take a timestamp here to neutralize the value during a short delay after the hard reset
  }
}

void i2c_rep_start(uint8_t address) {
  TWCR = (1<<TWINT) | (1<<TWSTA) | (1<<TWEN) | (1<<TWSTO); // send REAPEAT START condition
  waitTransmissionI2C(); // wait until transmission completed
 // checkStatusI2C(); // check value of TWI Status Register
  TWDR = address; // send device address
  TWCR = (1<<TWINT) | (1<<TWEN);
  waitTransmissionI2C(); // wail until transmission completed
 // checkStatusI2C(); // check value of TWI Status Register
}

void i2c_write(uint8_t data ) {	
  TWDR = data; // send data to the previously addressed device
  TWCR = (1<<TWINT) | (1<<TWEN);
  waitTransmissionI2C(); // wait until transmission completed
 // checkStatusI2C(); // check value of TWI Status Register
}

uint8_t i2c_readAck() {
  TWCR = (1<<TWINT) | (1<<TWEN) | (1<<TWEA);
  waitTransmissionI2C();
  return TWDR;
}

uint8_t i2c_readNak(void) {
  TWCR = (1<<TWINT) | (1<<TWEN);
  waitTransmissionI2C();
  return TWDR;
}
int     adc_value[8]   = { 0, 0, 0, 0, 0, 0, 0, 0 };
float     adc_flt[8]   = { 0, 0, 0, 0, 0, 0, 0, 0 };
int gyrozero[3]={0,0,0};
int rawADC_ITG3200[6],rawADC_BMA180[6];
long adc_read_timeout=0;



// Constructors ////////////////////////////////////////////////////////////////
AP_ADC_ADS7844::AP_ADC_ADS7844()
{
}

// Public Methods //////////////////////////////////////////////////////////////
void AP_ADC_ADS7844::Init(void)
{
 int i;
long gyrozeroL[3]={0,0,0};
//      Wire.begin();
i2c_init();
//=== ITG3200 INIT
for (i=0;i<8;i++) adc_flt[i]=0;

 delay(10);  
  TWBR = ((16000000L / 400000L) - 16) / 2; // change the I2C clock rate to 400kHz
 
  i2c_rep_start(0xd0+0);  // I2C write direction 
  i2c_write(0x3E);                   // Power Management register
  i2c_write(0x80);                   //   reset device
  delay(5);
  i2c_rep_start(0xd0+0);  // I2C write direction 
  i2c_write(0x15);                   // register Sample Rate Divider
  i2c_write(0x4);                    //   7: 1000Hz/(4+1) = 250Hz . 
  delay(5);
  i2c_rep_start(0xd0+0);  // I2C write direction 
  i2c_write(0x16);                   // register DLPF_CFG - low pass filter configuration & sample rate
  i2c_write(0x18+4);                   //   Internal Sample Rate 1kHz, 1..6: 1=200hz, 2-100,3-50,4-20,5-10,6-5
  delay(5);
  i2c_rep_start(0xd0+0);  // I2C write direction 
  i2c_write(0x3E);                   // Power Management register
  i2c_write(0x03);                   //   PLL with Z Gyro reference
  delay(100);
  
  

delay(10);
#ifndef BMA_020
 //===BMA180 INIT
  i2c_rep_start(BMA180_A+0);   // I2C write direction 
  i2c_write(0x0D);                   // ctrl_reg0
  i2c_write(1<<4);                   // Set bit 4 to 1 to enable writing
  i2c_rep_start(BMA180_A+0);       
  i2c_write(0x35);          
  i2c_write(3<<1);                   // range set to 3.  2730 1G raw data.  With /10 divisor on acc_ADC, more in line with other sensors and works with the GUI
  i2c_rep_start(BMA180_A+0);
  i2c_write(0x20);                   // bw_tcs reg: bits 4-7 to set bw
  i2c_write(0<<4);                   // bw to 10Hz (low pass filter)
#else
  byte control;				// BMA020 INIT
  
  i2c_rep_start(0x70);     // I2C write direction
  i2c_write(0x15);         // 
  i2c_write(0x80);         // Write B10000000 at 0x15 init BMA020

  i2c_rep_start(0x70);     // 
  i2c_write(0x14);         //  
  i2c_write(0x71);         // 
  i2c_rep_start(0x71);     //
  control = i2c_readNak();
 
  control = control >> 5;  //ensure the value of three fist bits of reg 0x14 see BMA020 documentation page 9
  control = control << 2;
  control = control | 0x00; //Range 2G 00
  control = control << 3;
  control = control | 0x00; //Bandwidth 25 Hz 000
 
  i2c_rep_start(0x70);     // I2C write direction
  i2c_write(0x14);         // Start multiple read at reg 0x32 ADX
  i2c_write(control);
#endif
 delay(10);  
 
 // Sonar INIT
//=======================
//D48 (PORTL.1) = sonar input
//D47 (PORTL.2) = sonar Tx (trigger)
//The smaller altitude then lower the cycle time

 // 0.034 cm/micros
//PORTL&=B11111001; 
//DDRL&=B11111101;
//DDRL|=B00000100;

PORTH&=B10111111; // H6 -d9  - sonar TX
DDRH |=B01000000;

PORTB&=B11101111; // B4 -d10 - sonar Echo
DDRB &=B11101111;


//PORTG|=B00000011; // buttons pullup

//div64 = 0.5 us/bit
//resolution =0.136cm
//full range =11m 33ms
 // Using timer5
   //Remember the registers not declared here remains zero by default... 
  TCCR5A =0; //standard mode with overflow at A and OC B and C interrupts
  TCCR5B = (1<<CS11); //Prescaler set to 8, resolution of 0.5us
  TIMSK5=B00000111; // ints: overflow, capture, compareA
  OCR5A=65510; // approx 10m limit, 33ms period
  OCR5B=3000;
}

// Sonar read interrupts
volatile char sonar_meas=0;
volatile int sonar_data=-1,sonic_range=-1,pre_sonar_data=-1,s_filter_index=0,s_filter[SONAR_FILTER_SIZE];
ISR(TIMER5_COMPA_vect) // measurement is over, no edge detected, Set up Tx pin, offset 12 us
{if (sonar_meas==0) sonar_data=0;PORTH|=B01000000;}
ISR(TIMER5_OVF_vect) // next measurement, clear the Tx pin, 
{PORTH&=B10111111;sonar_meas=0;}
//ISR(TIMER5_CAPT_vect) // measurement successful, next measurement
//{sonar_data=ICR5;sonar_meas=1;}
ISR(PCINT0_vect)
{if (!(PINB & B00010000)) {sonar_data=TCNT5;sonar_meas=1;}}


void i2c_ACC_getADC () { // ITG3200 read data
static uint8_t i;

  i2c_rep_start(0XD0);     // I2C write direction ITG3200
  i2c_write(0X1D);         // Start multiple read
  i2c_rep_start(0XD0 +1);  // I2C read direction => 1
  for(i = 0; i< 5; i++) {
  rawADC_ITG3200[i]=i2c_readAck();}
  rawADC_ITG3200[5]= i2c_readNak();
#ifdef ALLINONE
  adc_value[0] =  (((rawADC_ITG3200[4]<<8) | rawADC_ITG3200[5])-gyrozero[0]); //g yaw
  adc_value[1] =  (((rawADC_ITG3200[2]<<8) | rawADC_ITG3200[3])-gyrozero[1]); //g roll
  adc_value[2] =- (((rawADC_ITG3200[0]<<8) | rawADC_ITG3200[1])-gyrozero[2]); //g pitch
#endif
#ifdef FFIMU
  adc_value[0] =  (((rawADC_ITG3200[4]<<8) | rawADC_ITG3200[5])-gyrozero[0]); //g yaw
  adc_value[2] =  (((rawADC_ITG3200[2]<<8) | rawADC_ITG3200[3])-gyrozero[2]); //g roll
  adc_value[1] =  (((rawADC_ITG3200[0]<<8) | rawADC_ITG3200[1])-gyrozero[1]); //g pitch
#endif

#ifndef BMA_020
  i2c_rep_start(BMA180_A);     // I2C write direction BMA 180
  i2c_write(0x02);         // Start multiple read at reg 0x02 acc_x_lsb
  i2c_rep_start(BMA180_A +1);  // I2C read direction => 1
  for( i = 0; i < 5; i++) {
    rawADC_BMA180[i]=i2c_readAck();}
  rawADC_BMA180[5]= i2c_readNak();
#else // BMA020
  i2c_rep_start(0x70);
  i2c_write(0x02);
  i2c_write(0x71);  
  i2c_rep_start(0x71);
  for( i = 0; i < 5; i++) {
    rawADC_BMA180[i]=i2c_readAck();}
  rawADC_BMA180[5]= i2c_readNak();
  

#endif  
  
#ifdef ALLINONE
  adc_value[4] =  ((rawADC_BMA180[3]<<8) | (rawADC_BMA180[2]))/ACC_DIV; //a pitch
  adc_value[5] = -((rawADC_BMA180[1]<<8) | (rawADC_BMA180[0]))/ACC_DIV; //a roll
  adc_value[6] =  ((rawADC_BMA180[5]<<8) | (rawADC_BMA180[4]))/ACC_DIV; //a yaw
#endif
#ifdef FFIMU
  adc_value[5] =  ((rawADC_BMA180[3]<<8) | (rawADC_BMA180[2]))/ACC_DIV; //a pitch
  adc_value[4] =  ((rawADC_BMA180[1]<<8) | (rawADC_BMA180[0]))/ACC_DIV; //a roll
  adc_value[6] =  ((rawADC_BMA180[5]<<8) | (rawADC_BMA180[4]))/ACC_DIV; //a yaw
#endif
}

// Read one channel value
int AP_ADC_ADS7844::Ch(unsigned char ch_num)         
{char i;int flt;
	if (ch_num==7) {
		#ifdef SONARFILTER
			// simple filter
			// don't use big value of SONAR_FILTER_SIZE
			if (sonar_data==0) {
				sonar_data=pre_sonar_data;
			} else {
				s_filter[s_filter_index]=sonar_data;
				s_filter_index++;
				sonar_data=0;
				if(s_filter_index >= SONAR_FILTER_SIZE) s_filter_index = 0;
				for(byte i = 0; i < SONAR_FILTER_SIZE; i++){
					sonar_data += s_filter[s_filter_index];
				}
				sonar_data=sonar_data/SONAR_FILTER_SIZE;
			}
		#else
			if (sonar_data==0) sonar_data=pre_sonar_data;	//wrong data from sonar, use preview (test with DYPME007v2)
		#endif
		#ifdef DYPME007
			
			// Syberian version
			if (sonar_data<80) return(32767);
			if (sonar_data<2160) sonar_data=2160;
			sonic_range=0.0081175*sonar_data;
			
			/*if (sonar_data<3000){
				sonic_range=0;			// min_value of distance in cm
			} else if (sonar_data>11000) {
				sonic_range=150;		// max_value of distance in cm
			} else {
				sonic_range=(sonar_data)*0.011; //(its in cm)
			}
			pre_sonar_data=sonar_data;*/
		#endif

		#ifdef DYPME007v2
			if (sonar_data>-3000){
				sonic_range=150;	// max_value of distance in cm
			} else if (sonar_data<-19000) {
				sonic_range=0;		// min_value of distance in cm
			} else {
				sonic_range=(sonar_data+20000)*0.0083; //(its in cm)
			}
			pre_sonar_data=sonar_data;
		#endif
		#ifdef SONARDEBUG
			sonic_range=sonar_data; //(its in parots)
		#endif
		return(sonic_range);
	} else  { // channels 0..6
		if ( (millis()-adc_read_timeout )  > 2 )  //each read is spaced by 3ms else place old values
		{  adc_read_timeout = millis();
			i2c_ACC_getADC ();
		}
		if (ch_num<4)	return(adc_value[ch_num]/6);	// gyro
		else		return(adc_value[ch_num]);	// acc
	}
}	

// Read one channel value
int AP_ADC_ADS7844::Ch_raw(unsigned char ch_num)
{
	return _filter[ch_num][_filter_index]; // close enough
}
