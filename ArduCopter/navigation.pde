// -*- tab-width: 4; Mode: C++; c-basic-offset: 4; indent-tabs-mode: nil -*-

//****************************************************************
// Function that will calculate the desired direction to fly and distance
//****************************************************************
static byte navigate()
{
	if(next_WP.lat == 0){
		return 0;
	}

	// waypoint distance from plane
	// ----------------------------
	wp_distance = get_distance(&current_loc, &next_WP);

	if (wp_distance < 0){
		//gcs_send_text_P(SEVERITY_HIGH,PSTR("<navigate> WP error - distance < 0"));
		//Serial.println(wp_distance,DEC);
		//print_current_waypoints();
		return 0;
	}

	// target_bearing is where we should be heading
	// --------------------------------------------
	target_bearing 	= get_bearing(&current_loc, &next_WP);
	return 1;
}

static bool check_missed_wp()
{
	long temp 	= target_bearing - original_target_bearing;
	temp 		= wrap_180(temp);
	return (abs(temp) > 10000);	//we pased the waypoint by 10 °
}

// ------------------------------

// long_error, lat_error
static void calc_location_error(struct Location *next_loc)
{
	/*
	Becuase we are using lat and lon to do our distance errors here's a quick chart:
	100 	= 1m
	1000 	= 11m	 = 36 feet
	1800 	= 19.80m = 60 feet
	3000 	= 33m
	10000 	= 111m
	pitch_max = 22° (2200)
	*/

	// X ROLL
	long_error	= (float)(next_loc->lng - current_loc.lng) * scaleLongDown;   // 500 - 0 = 500 roll EAST

	// Y PITCH
	lat_error	= next_loc->lat - current_loc.lat;							// 0 - 500 = -500 pitch NORTH
}

#define NAV_ERR_MAX 800
static void calc_loiter(int x_error, int y_error)
{
	x_error = constrain(x_error, -NAV_ERR_MAX, NAV_ERR_MAX);
	y_error = constrain(y_error, -NAV_ERR_MAX, NAV_ERR_MAX);

	int x_target_speed = g.pi_loiter_lon.get_pi(x_error, dTnav);
	int y_target_speed = g.pi_loiter_lat.get_pi(y_error, dTnav);

	// find the rates:
	float temp		= radians((float)g_gps->ground_course/100.0);

	#ifdef OPTFLOW_ENABLED
	// calc the cos of the error to tell how fast we are moving towards the target in cm
		if(g.optflow_enabled && current_loc.alt < 500 &&  g_gps->ground_speed < 150){
			x_actual_speed 	= optflow.vlon * 10;
			y_actual_speed 	= optflow.vlat * 10;
		}else{
			x_actual_speed 	= (float)g_gps->ground_speed * sin(temp);
			y_actual_speed 	= (float)g_gps->ground_speed * cos(temp);
		}
	#else
		x_actual_speed 	= (float)g_gps->ground_speed * sin(temp);
		y_actual_speed 	= (float)g_gps->ground_speed * cos(temp);
	#endif

	y_rate_error 	= y_target_speed - y_actual_speed; // 413
	y_rate_error 	= constrain(y_rate_error, -250, 250);	// added a rate error limit to keep pitching down to a minimum
	nav_lat		 	= g.pi_nav_lat.get_pi(y_rate_error, dTnav);
	nav_lat			= constrain(nav_lat, -3500, 3500);

	x_rate_error 	= x_target_speed - x_actual_speed;
	x_rate_error 	= constrain(x_rate_error, -250, 250);
	nav_lon		 	= g.pi_nav_lon.get_pi(x_rate_error, dTnav);
	nav_lon			= constrain(nav_lon, -3500, 3500);
}

// nav_roll, nav_pitch
static void calc_loiter_pitch_roll()
{

	float temp  	 = radians((float)(9000 - (dcm.yaw_sensor))/100.0);
	float _cos_yaw_x = cos(temp);
	float _sin_yaw_y = sin(temp);

//	Serial.printf("ys %ld, cyx %1.4f, _cyx %1.4f\n", dcm.yaw_sensor, cos_yaw_x, _cos_yaw_x);

	// rotate the vector
	nav_roll 	=  (float)nav_lon * _sin_yaw_y - (float)nav_lat * _cos_yaw_x;
	nav_pitch 	=  (float)nav_lon * _cos_yaw_x + (float)nav_lat * _sin_yaw_y;

	// flip pitch because forward is negative
	nav_pitch = -nav_pitch;
}

static void calc_nav_rate(int max_speed)
{
	/*
	0  1   2   3   4   5   6   7   8
	...|...|...|...|...|...|...|...|
		  100	  200	  300	  400
	                                     +|+
	*/
	max_speed 		= min(max_speed, (wp_distance * 50));

	// limit the ramp up of the speed
	if(waypoint_speed_gov < max_speed){

		waypoint_speed_gov += (int)(150.0 * dTnav); // increase at 1.5/ms

		// go at least 1m/s
		max_speed 		= max(100, waypoint_speed_gov);
		// limit with governer
		max_speed 		= min(max_speed, waypoint_speed_gov);
	}

	// XXX target_angle should be the original  desired target angle!
	float temp		= radians((original_target_bearing - g_gps->ground_course)/100.0);

	x_actual_speed 	= -sin(temp) * (float)g_gps->ground_speed;
	x_rate_error 	= -x_actual_speed;
	x_rate_error 	= constrain(x_rate_error, -800, 800);
	nav_lon		 	= constrain(g.pi_nav_lon.get_pi(x_rate_error, dTnav), -3500, 3500);

	y_actual_speed 	= cos(temp) * (float)g_gps->ground_speed;
	y_rate_error 	= max_speed - y_actual_speed; // 413
	y_rate_error 	= constrain(y_rate_error, -800, 800);	// added a rate error limit to keep pitching down to a minimum
	nav_lat		 	= constrain(g.pi_nav_lat.get_pi(y_rate_error, dTnav), -3500, 3500);

	/*Serial.printf("max_speed: %d, xspeed: %d, yspeed: %d, x_re: %d, y_re: %d, nav_lon: %ld, nav_lat: %ld  ",
					max_speed,
					x_actual_speed,
					y_actual_speed,
					x_rate_error,
					y_rate_error,
					nav_lon,
					nav_lat);*/
}

// nav_roll, nav_pitch
static void calc_nav_pitch_roll()
{
	float temp  	 = radians((float)(9000 - (dcm.yaw_sensor - original_target_bearing))/100.0);
	float _cos_yaw_x = cos(temp);
	float _sin_yaw_y = sin(temp);

	// rotate the vector
	nav_roll 	=  (float)nav_lon * _sin_yaw_y - (float)nav_lat * _cos_yaw_x;
	nav_pitch 	=  (float)nav_lon * _cos_yaw_x + (float)nav_lat * _sin_yaw_y;

	// flip pitch because forward is negative
	nav_pitch = -nav_pitch;

	/*Serial.printf("_cos_yaw_x:%1.4f, _sin_yaw_y:%1.4f, nav_roll:%ld, nav_pitch:%ld\n",
					_cos_yaw_x,
					_sin_yaw_y,
					nav_roll,
					nav_pitch);*/
}

static long get_altitude_error()
{
	return next_WP.alt - current_loc.alt;
}

static int get_loiter_angle()
{
	float power;
	int angle;

	if(wp_distance <= g.loiter_radius){
		power = float(wp_distance) / float(g.loiter_radius);
		power = constrain(power, 0.5, 1);
		angle = 90.0 * (2.0 + power);
	}else if(wp_distance < (g.loiter_radius + LOITER_RANGE)){
		power = -((float)(wp_distance - g.loiter_radius - LOITER_RANGE) / LOITER_RANGE);
		power = constrain(power, 0.5, 1);			//power = constrain(power, 0, 1);
		angle = power * 90;
	}

	return angle;
}

static long wrap_360(long error)
{
	if (error > 36000)	error -= 36000;
	if (error < 0)		error += 36000;
	return error;
}

static long wrap_180(long error)
{
	if (error > 18000)	error -= 36000;
	if (error < -18000)	error += 36000;
	return error;
}

/*
static long get_crosstrack_correction(void)
{
	// Crosstrack Error
	// ----------------
	if (cross_track_test() < 9000) {	 // If we are too far off or too close we don't do track following

		// Meters we are off track line
		float error = sin(radians((target_bearing - crosstrack_bearing) / (float)100)) * (float)wp_distance;

		// take meters * 100 to get adjustment to nav_bearing
		long _crosstrack_correction = g.pi_crosstrack.get_pi(error, dTnav) * 100;

		// constrain answer to 30° to avoid overshoot
		return constrain(_crosstrack_correction, -g.crosstrack_entry_angle.get(), g.crosstrack_entry_angle.get());
	}
    return 0;
}
*/
/*
static long cross_track_test()
{
	long temp = wrap_180(target_bearing - crosstrack_bearing);
	return abs(temp);
}
*/
/*
static void reset_crosstrack()
{
	crosstrack_bearing 	= get_bearing(&current_loc, &next_WP);	// Used for track following
}
*/
/*static long get_altitude_above_home(void)
{
	// This is the altitude above the home location
	// The GPS gives us altitude at Sea Level
	// if you slope soar, you should see a negative number sometimes
	// -------------------------------------------------------------
	return current_loc.alt - home.alt;
}
*/
// distance is returned in meters
static long get_distance(struct Location *loc1, struct Location *loc2)
{
	//if(loc1->lat == 0 || loc1->lng == 0)
	//	return -1;
	//if(loc2->lat == 0 || loc2->lng == 0)
	//	return -1;
	float dlat 		= (float)(loc2->lat - loc1->lat);
	float dlong		= ((float)(loc2->lng - loc1->lng)) * scaleLongDown;
	return sqrt(sq(dlat) + sq(dlong)) * .01113195;
}
/*
static long get_alt_distance(struct Location *loc1, struct Location *loc2)
{
	return abs(loc1->alt - loc2->alt);
}
*/
static long get_bearing(struct Location *loc1, struct Location *loc2)
{
	long off_x = loc2->lng - loc1->lng;
	long off_y = (loc2->lat - loc1->lat) * scaleLongUp;
	long bearing =	9000 + atan2(-off_y, off_x) * 5729.57795;
	if (bearing < 0) bearing += 36000;
	return bearing;
}
