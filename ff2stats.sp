/*

freak fortress 2 status, written by nitros

*/

#pragma semicolon 1

#include <sourcemod>
#include <freak_fortress_2>
#include <clientprefs>

#define PLUGIN_VERSION "0.0.1"

#define STATS_COOKIE "ff2stats_onforuser"


public Plugin:myinfo=
{
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
}

public Action:statsToggleCmd(int client, int args)
{
	if(!IsValidClient(client))
	{
		return Plugin_Continue;
	}

	statsTogglePanel(client);
	return Plugin_Handled;
}

public Action:statsTogglePanel(client)
{
	if(!IsValidClient(client))
	{
		return Plugin_Continue;
	}

	new Handle:panel=CreatePanel();
	SetPanelTitle(panel, "Turn stats for you when you're boss...");
	DrawPanelItem(panel, "On");
	DrawPanelItem(panel, "Off");
	SendPanelToClient(panel, client, statsTogglePanelH, MENU_TIME_FOREVER);
	CloseHandle(panel);
	return Plugin_Continue;
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
			//If they already have music enabled don't do anything
			setStatsCookie(client, true);
		}
		CPrintToChat(client, "{olive}[FF2stats]{default} %t", "ff2stats", selection==2 ? "off" : "on");
	}
}


InitDB(&Handle:DBHandle)
{
  new String:Error[255];
  DBHandle = SQL_Connect("stats_db", true, Error, sizeof(Error));

  if(DBHandle == INVALID_HANDLE)
  {
    SetFailState(Error);
  }
  new String:Query[255];
  Format(Query, sizeof(Query), "CREATE TABLE IF NOT EXISTS player_stats (steamid INT, bossname TEXT, win INT)");
  SQL_LockDatabase(DBHandle);
  SQL_FastQuery(DBHandle, Query);
  SQL_UnlockDatabase(DBHandle);
}


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

void addGameToDB(int steamid, const char[] boss_name, bool win)
{
  char query[200];

  /* Create enough space to make sure our string is quoted properly  */
  int buffer_len = strlen(boss_name) * 2 + 1;
  char[] new_boss_name = new char[buffer_len];

  /* Ask the SQL driver to make sure our string is safely quoted */
  SQL_EscapeString(db, boss_name, new_boss_name, buffer_len);

  /* Build the query */
  Format(query, sizeof(query), "INSERT INTO <tablehere> (steamid, bossname, win) VALUES (%d, '%s', %d)", steamid, new_boss_name, win);

  /* Execute the query */
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
    if(!StatsEnabledForClient(client)){continue;} // dont add if not counting stats
    boss=FF2_GetBossIndex(client);
    if(!(boss==-1)) // we have a boss
    {
      new bossSteamID = GetSteamAccountID(client); // steamid
      if (bossSteamID==0){continue;} // dont break on invalid steamid
      FF2_GetBossSpecial(boss, bossName, sizeof(bossName));
      addGameToDB(bossSteamID, bossName, bossWin);
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
