/// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-
static int
get_stabilize_roll(int32_t target_angle)
{
	int32_t error;
	int32_t rate;

	error 		= wrap_180(target_angle - dcm.roll_sensor);

	// limit the error we're feeding to the PID
	error 		= constrain(error, -2500, 2500);

	// desired Rate:
	rate 		= g.pi_stabilize_roll.get_pi(error, G_Dt);
	//Serial.printf("%d\t%d\t%d ", (int)target_angle, (int)error, (int)rate);

#if FRAME_CONFIG != HELI_FRAME  // cannot use rate control for helicopters
	// Rate P:
	error 		= rate - (degrees(omega.x) * 100.0);
	rate 		= g.pi_rate_roll.get_pi(error, G_Dt);
	//Serial.printf("%d\t%d\n", (int)error, (int)rate);
#endif

	// output control:
	return (int)constrain(rate, -2500, 2500);
}

static int
get_stabilize_pitch(int32_t target_angle)
{
	int32_t error;
	int32_t rate;

	error 		= wrap_180(target_angle - dcm.pitch_sensor);

	// limit the error we're feeding to the PID
	error 		= constrain(error, -2500, 2500);

	// desired Rate:
	rate 		= g.pi_stabilize_pitch.get_pi(error, G_Dt);
	//Serial.printf("%d\t%d\t%d ", (int)target_angle, (int)error, (int)rate);

#if FRAME_CONFIG != HELI_FRAME  // cannot use rate control for helicopters
	// Rate P:
	error 		= rate - (degrees(omega.y) * 100.0);
	rate 		= g.pi_rate_pitch.get_pi(error, G_Dt);
	//Serial.printf("%d\t%d\n", (int)error, (int)rate);
#endif

	// output control:
	return (int)constrain(rate, -2500, 2500);
}


#define YAW_ERROR_MAX 2000
static int
get_stabilize_yaw(int32_t target_angle)
{
	int32_t error;
	int32_t rate;

	yaw_error 		= wrap_180(target_angle - dcm.yaw_sensor);

	// limit the error we're feeding to the PID
	yaw_error 		= constrain(yaw_error, -YAW_ERROR_MAX, YAW_ERROR_MAX);
	rate 			= g.pi_stabilize_yaw.get_pi(yaw_error, G_Dt);
	//Serial.printf("%u\t%d\t%d\t", (int)target_angle, (int)error, (int)rate);

#if FRAME_CONFIG == HELI_FRAME  // cannot use rate control for helicopters
	if( ! g.heli_ext_gyro_enabled ) {
		// Rate P:
		error 		= rate - (degrees(omega.z) * 100.0);
		rate 		= g.pi_rate_yaw.get_pi(error, G_Dt);
	}

	// output control:
	return (int)constrain(rate, -4500, 4500);
#else
	// Rate P:
	error 			= rate - (degrees(omega.z) * 100.0);
	rate 			= g.pi_rate_yaw.get_pi(error, G_Dt);
	//Serial.printf("%d\t%d\n", (int)error, (int)rate);

	// output control:
	return (int)constrain(rate, -2500, 2500);
#endif

}

#define ALT_ERROR_MAX 300
static int
get_nav_throttle(int32_t z_error)
{
	bool calc_i = (abs(z_error) < ALT_ERROR_MAX);
	// limit error to prevent I term run up
	z_error 		= constrain(z_error, -ALT_ERROR_MAX, ALT_ERROR_MAX);
	int rate_error 	= g.pi_alt_hold.get_pi(z_error, .1, calc_i); //_p = .85
	rate_error 		= rate_error - climb_rate;

	// limit the rate
	return constrain((int)g.pi_throttle.get_pi(rate_error, .1), -120, 180);
}

static int
get_rate_roll(int32_t target_rate)
{
	int32_t error	= (target_rate * 3.5) - (degrees(omega.x) * 100.0);
	return g.pi_acro_roll.get_pi(error, G_Dt);
}

static int
get_rate_pitch(int32_t target_rate)
{
	int32_t error	= (target_rate * 3.5) - (degrees(omega.y) * 100.0);
	return  g.pi_acro_pitch.get_pi(error, G_Dt);
}

static int
get_rate_yaw(int32_t target_rate)
{
	int32_t error;
	error		= (target_rate * 4.5) - (degrees(omega.z) * 100.0);
	target_rate = g.pi_rate_yaw.get_pi(error, G_Dt);

	// output control:
	return (int)constrain(target_rate, -2500, 2500);
}


// Zeros out navigation Integrators if we are changing mode, have passed a waypoint, etc.
// Keeps outdated data out of our calculations
static void reset_hold_I(void)
{
	g.pi_loiter_lat.reset_I();
	g.pi_loiter_lon.reset_I();
	g.pi_crosstrack.reset_I();
}

// Zeros out navigation Integrators if we are changing mode, have passed a waypoint, etc.
// Keeps outdated data out of our calculations
static void reset_nav(void)
{
	nav_throttle 			= 0;
	invalid_throttle 		= true;

	g.pi_nav_lat.reset_I();
	g.pi_nav_lon.reset_I();

	circle_angle			= 0;
	crosstrack_error 		= 0;
	nav_lat 				= 0;
	nav_lon 				= 0;
	nav_roll 				= 0;
	nav_pitch 				= 0;
	target_bearing 			= 0;
	wp_distance 			= 0;
	wp_totalDistance 		= 0;
	long_error 				= 0;
	lat_error  				= 0;
}


/*************************************************************
throttle control
****************************************************************/

static long
get_nav_yaw_offset(int yaw_input, int reset)
{
	int32_t _yaw;

	if(reset == 0){
		// we are on the ground
		return dcm.yaw_sensor;

	}else{
		// re-define nav_yaw if we have stick input
		if(yaw_input != 0){
			// set nav_yaw + or - the current location
			_yaw = yaw_input + dcm.yaw_sensor;
			// we need to wrap our value so we can be 0 to 360 (*100)
			return wrap_360(_yaw);

		}else{
			// no stick input, lets not change nav_yaw
			return nav_yaw;
		}
	}
}

static int get_angle_boost(int value)
{
	float temp = cos_pitch_x * cos_roll_x;
	temp = 1.0 - constrain(temp, .5, 1.0);
	return (int)(temp * value);
}

// Accelerometer Z dampening by Aurelio R. Ramos
// ---------------------------------------------

#if ACCEL_ALT_HOLD == 1

// contains G and any other DC offset
static float estimatedAccelOffset = 0;

// state
static float synVelo = 0;
static float synPos = 0;
static float synPosFiltered = 0;
static float posError = 0;
static float prevSensedPos = 0;

// tuning for dead reckoning
static const float dt_50hz = 0.02;
static float synPosP = 10 * dt_50hz;
static float synPosI = 15 * dt_50hz;
static float synVeloP = 1.5 * dt_50hz;
static float maxVeloCorrection = 5 * dt_50hz;
static float maxSensedVelo = 1;
static float synPosFilter = 0.5;

#define NUM_G_SAMPLES 200

// Z damping term.
static float fullDampP = 0.100;

float get_world_Z_accel()
{
	Vector3f accels_rot = dcm.get_dcm_matrix() * imu.get_accel();
	return accels_rot.z;
}


static void init_z_damper()
{
	estimatedAccelOffset = 0;
	for (int i = 0; i < NUM_G_SAMPLES; i++){
		estimatedAccelOffset += get_world_Z_accel();
	}
	estimatedAccelOffset /= (float)NUM_G_SAMPLES;
}

float dead_reckon_Z(float sensedPos, float sensedAccel)
{
	// the following algorithm synthesizes position and velocity from
	// a noisy altitude and accelerometer data.

	// synthesize uncorrected velocity by integrating acceleration
	synVelo += (sensedAccel - estimatedAccelOffset) * dt_50hz;

	// synthesize uncorrected position by integrating uncorrected velocity
	synPos += synVelo * dt_50hz;

	// filter synPos, the better this filter matches the filtering and dead time
	// of the sensed position, the less the position estimate will lag.
	synPosFiltered = synPosFiltered * (1 - synPosFilter) + synPos * synPosFilter;

	// calculate error against sensor position
	posError = sensedPos - synPosFiltered;

	// correct altitude
	synPos += synPosP * posError;

	// correct integrated velocity by posError
	synVelo = synVelo + constrain(posError, -maxVeloCorrection, maxVeloCorrection) * synPosI;

	// correct integrated velocity by the sensed position delta in a small proportion
	// (i.e., the low frequency of the delta)
	float sensedVelo = (sensedPos - prevSensedPos) / dt_50hz;
	synVelo += constrain(sensedVelo - synVelo, -maxSensedVelo, maxSensedVelo) * synVeloP;

	prevSensedPos = sensedPos;
	return synVelo;
}

static int get_z_damping()
{
	float sensedAccel = get_world_Z_accel();
	float sensedPos = current_loc.alt / 100.0;

	float synVelo = dead_reckon_Z(sensedPos, sensedAccel);
	return constrain(fullDampP * synVelo * (-1), -300, 300);
}

#else

static int get_z_damping()
{
	return 0;
}

#endif




