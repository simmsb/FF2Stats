/*

freak fortress 2 status, written by nitros


that big TODO: list

on round start:
	do stats stuff
	hp mod:
		(wins / (wins + loss)) => win_percentage  <- Done in SQL

		new_mod = ((win_percentage^2) * sign(win_percentage)) <- Done in SM

	Easy/ Med/ Hard gamemodes?
*/

// TODO: Move these func somewhere else once implemented
int calcHpMod(float win_percentage, int base_hp) {
	float multiplier = f_clamp(pow(win_percentage, 2.0) * F_SIGN(win_percentage), -0.5, 0.5) + 1.0;
	return FloatRound(multiplier * base_hp);
}

float f_clamp(float val, float min, float max) {
	if (val < min) {
		return min;
	} else if (val > max) {
		return max;
	} else {
		return val;
	}
}


#pragma semicolon 1

#include <sourcemod>
#include <freak_fortress_2>
#include <clientprefs>

#define PLUGIN_VERSION "0.1.1"

#define STATS_COOKIE "ff2stats_onforuser"
#define STATS_TABLE "player_stats"

#define F_SIGN(%1) ((%1)>0.0 ? 1.0 : -1.0)


public Plugin:myinfo = {
	name="Freak Fortress Stats",
	author="Nitros",
	description="Boss stats for freak fortress 2",
	version=PLUGIN_VERSION,
  url="ben@bensimms.moe"
};

new Handle:g_bossStatsCookie;
new Handle:db;

public void OnPluginStart()
{
	g_bossStatsCookie = RegClientCookie(STATS_COOKIE, "Enable stats for user", CookieAccess_Protected);
  InitDB(db);
  HookEvent("teamplay_round_win", OnRoundEnd);
  RegConsoleCmd("ff2stats", statsToggleCmd);
	LoadTranslations("ff2stats.phrases");
}

//
//			STATS CLEARING MENU
//
public Action:statsClearCmd(int client, int args)
{
	if(!IsValidClient(client)) {
		return Plugin_Handled;
	}

	statsClearPanel(client);
	return Plugin_Handled;
}

public Action:statsClearPanel(client)
{
	new Handle:panel=CreatePanel();
	SetPanelTitle(panel, "Are you sure you want to clear your boss stats!");
	DrawPanelItem(panel, "Yes");
	DrawPanelItem(panel, "No");
	SendPanelToClient(panel, client, statsClearPanelH, MENU_TIME_FOREVER);
	CloseHandle(panel);
	return Plugin_Handled;
}

public statsClearPanelH(Handle:menu, MenuAction:action, client, selection)
{
	if(IsValidClient(client) && action==MenuAction_Select)
	{
		if(selection==1)  //Yes
		{
			removeUserStats(GetSteamAccountID(client));
			CPrintToChat(client, "{olive}[FF2stats]{default} Cleared your boss stats!");
		}
	}
}
//
//
//


//
//			STATS TOGGLE MENU
//
public Action:statsToggleCmd(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Handled;
	}

	statsTogglePanel(client);
	return Plugin_Handled;
}

public Action:statsTogglePanel(client)
{
	new Handle:panel=CreatePanel();
	SetPanelTitle(panel, "Enable or disable boss stats");
	DrawPanelItem(panel, "On");
	DrawPanelItem(panel, "Off");
	SendPanelToClient(panel, client, statsTogglePanelH, MENU_TIME_FOREVER);
	CloseHandle(panel);
	return Plugin_Handled;
}

public statsTogglePanelH(Handle:menu, MenuAction:action, client, selection)
{
	if(IsValidClient(client) && action==MenuAction_Select)
	{
		if(selection==2)  //Off
		{
			setStatsCookie(client, false);
		}
		else  //On
		{
			setStatsCookie(client, true);
		}
		CPrintToChat(client, "{olive}[FF2stats]{default} FF2stats are %t for you!", selection==2 ? "off" : "on");
	}
}
//
//
//


InitDB(&Handle:DBHandle)
{
  new String:Error[255];
  DBHandle = SQL_Connect("default", true, Error, sizeof(Error));

  if(DBHandle == INVALID_HANDLE)
  {
    SetFailState(Error);
  }
  new String:Query[255];
  Format(Query, sizeof(Query), "CREATE TABLE IF NOT EXISTS %s (steamid INT, bossname TEXT, win INT)", STATS_TABLE);
  SQL_LockDatabase(DBHandle);
  SQL_FastQuery(DBHandle, Query);
  SQL_UnlockDatabase(DBHandle);
}


//	set stats cookie for client, type: bool
setStatsCookie(int client, bool val)
{
  if(!IsValidClient(client) || IsFakeClient(client) || !AreClientCookiesCached(client))
  {
    return;
  }
  char cookieVal[8];
  IntToString(val, cookieVal, sizeof(cookieVal));
  SetClientCookie(client, g_bossStatsCookie, cookieVal);
}


//	Get val of stats cookie for client
bool StatsEnabledForClient(int client)
{
  if(!AreClientCookiesCached(client)) // not loaded? dont run stats
  {
    return false;
  }
  decl String:sValue[8];
  GetClientCookie(client, g_bossStatsCookie, sValue, sizeof(sValue));
  return (sValue[0] != '\0' && StringToInt(sValue));
}


// insert game into database
//
//		steamid <int>: Steamid of client
//		boss_name <char[]>: name of boss (Only thing that is garunteed to not change often)
//		win <bool>:	true -> boss won, false -> boss lost
void addGameToDB(int steamid, const char[] boss_name, bool win)
{
  char query[255];

  /* Create enough space to make sure our string is quoted properly  */
  int buffer_len = strlen(boss_name) * 2 + 1;
  char[] new_boss_name = new char[buffer_len];

  /* Ask the SQL driver to make sure our string is safely quoted */
  SQL_EscapeString(db, boss_name, new_boss_name, buffer_len);

  /* Build the query */
  Format(query, sizeof(query), "INSERT INTO %s (steamid, bossname, win) VALUES (%d, '%s', %d);", STATS_TABLE, steamid, new_boss_name, win);
  /* Execute the query */
  SQL_LockDatabase(db);
  SQL_FastQuery(db, query);
  SQL_UnlockDatabase(db);
}


void removeUserStats(int steamid)
{
	char query[255];

	Format(query, sizeof(query), "DELETE FROM %s WHERE steamid=%d;", STATS_TABLE, steamid);

	SQL_LockDatabase(db);
	SQL_FastQuery(db, query);
	SQL_UnlockDatabase(db);
}


public Action:OnRoundEnd(Handle:event, const String:name[], bool:dontBroadcast)
{
  if(!FF2_IsFF2Enabled())
  {
    return Plugin_Continue;
  }
  new bool:bossWin=false;
  if((GetEventInt(event, "team")==FF2_GetBossTeam()))
  {
    bossWin=true; // boss won
  }
  decl String:bossName[64];
  new boss = -1;
  for(new client; client<MaxClients; client++)
  {
		if(IsValidClient(client)){
	    if (!StatsEnabledForClient(client)) {
				continue;
			} // dont add if not counting stats
	    boss=FF2_GetBossIndex(client);
	    if (!(boss==-1)) { // we have a boss
	      new bossSteamID = GetSteamAccountID(client); // steamid
	      if (bossSteamID==0) {
					continue;
				} // dont break on invalid steamid
	      FF2_GetBossSpecial(boss, bossName, sizeof(bossName));
				CPrintToChat(client, "{olive}[FF2stats]{default} FF2stats are enabled for you, a %s was counted for %s.", bossWin==true ? "win" : "loss", bossName);
	    	addGameToDB(bossSteamID, bossName, bossWin);
	    }
		}
  }

  return Plugin_Continue;
}

stock bool:IsValidClient(client, bool:replaycheck=true)
{
	if(client<=0 || client>MaxClients)
	{
		return false;
	}

	if(!IsClientInGame(client))
	{
		return false;
	}

	if(GetEntProp(client, Prop_Send, "m_bIsCoaching"))
	{
		return false;
	}

	if(replaycheck)
	{
		if(IsClientSourceTV(client) || IsClientReplay(client))
		{
			return false;
		}
	}
	return true;
}
