/* USER CODE BEGIN Header */
/**
  ******************************************************************************
  * @file           : main.c
  * @brief          : Main program body
  ******************************************************************************
  * @attention
  *
  * Copyright (c) 2026 STMicroelectronics.
  * All rights reserved.
  *
  * This software is licensed under terms that can be found in the LICENSE file
  * in the root directory of this software component.
  * If no LICENSE file comes with this software, it is provided AS-IS.
  *
  ******************************************************************************
  */
/* USER CODE END Header */
/* Includes ------------------------------------------------------------------*/
#include "main.h"

/* Private includes ----------------------------------------------------------*/
/* USER CODE BEGIN Includes */
#include <string.h>
#include <stdio.h>
#include "DFRobot_PH.h"
#include <stdlib.h>
#include <math.h>
#include "liquidcrystal_i2c.h"
#include <stdbool.h>
/* USER CODE END Includes */

/* Private typedef -----------------------------------------------------------*/
/* USER CODE BEGIN PTD */

/* USER CODE END PTD */

/* Private define ------------------------------------------------------------*/
/* USER CODE BEGIN PD */

/* USER CODE END PD */

/* Private macro -------------------------------------------------------------*/
/* USER CODE BEGIN PM */

/* USER CODE END PM */

/* Private variables ---------------------------------------------------------*/
ADC_HandleTypeDef hadc1;

I2C_HandleTypeDef hi2c1;

RTC_HandleTypeDef hrtc;

UART_HandleTypeDef huart1;
UART_HandleTypeDef huart2;
UART_HandleTypeDef huart3;
UART_HandleTypeDef huart6;
DMA_HandleTypeDef hdma_usart1_rx;
DMA_HandleTypeDef hdma_usart1_tx;

/* USER CODE BEGIN PV */
DFRobot_PH_t ph_sensor;
volatile uint32_t ADC_VAL[3];
int presence=0 , isRxed=0 , Temp_LSB=0 ,  Temp_MSB =0;
uint8_t RxData[8];
uint32_t Temp;
float Temperature;

char tempStr[200];
char turStr[16];
char phStr[16];
char ecStr[16];
char debug[200];
#define TEMP_DELAY_DEFAULT 1
#define CON_DELAY_DEFAULT  2
#define TUR_DELAY_DEFAULT  3
#define PH_DELAY_DEFAULT   4
#define MAX_GSM_NUMBERS     5
// Execution flags
volatile uint8_t trigger_temp = 0;
volatile uint8_t trigger_ph = 0;
volatile uint8_t trigger_con = 0;
volatile uint8_t trigger_tur = 0;
// Software counters
volatile uint32_t temp_delay_minutes = TEMP_DELAY_DEFAULT;
volatile uint32_t con_delay_minutes  = CON_DELAY_DEFAULT;
volatile uint32_t tur_delay_minutes  = TUR_DELAY_DEFAULT;
volatile uint32_t ph_delay_minutes   = PH_DELAY_DEFAULT;

/* Software counters */
volatile uint32_t temp_counter = TEMP_DELAY_DEFAULT;
volatile uint32_t ph_counter   = PH_DELAY_DEFAULT;
volatile uint32_t tur_counter  = TUR_DELAY_DEFAULT;
volatile uint32_t con_counter  = CON_DELAY_DEFAULT;

#define UART6_RX_BUF_SIZE 128

/* -- Buffer réception USART6 ------------------------------------------------ */
static uint8_t rxByteBuf;                   /* octet reçu en IT              */
static uint8_t rxLineBuf[UART6_RX_BUF_SIZE]; /* ligne  courts d'assemblage   */

static uint16_t rxLineIdx = 0;
static volatile uint8_t lineReady = 0;
static uint8_t lineComplete [UART6_RX_BUF_SIZE];
// ec calibration
volatile uint8_t ec_calibration_mode = 0;

float ec_voltage1 = 0.0f;
float ec_voltage2 = 0.0f;

float ec_cal_point1 = 0.0f;
float ec_cal_point2 = 0.0f;

uint8_t ec_has_point1 = 0;
uint8_t ec_has_point2 = 0;

float ec_slope = 1.0f;
float ec_offset = 0.0f;
/* USER CODE END PV */
int gsm=0;
#define MAX_GSM_NUMBERS 5
#define GSM_NUMBER_LENGTH 18

char phoneNumbers[MAX_GSM_NUMBERS][GSM_NUMBER_LENGTH];
uint8_t gsm_number_count = 0;

/* Private function prototypes -----------------------------------------------*/
void SystemClock_Config(void);
static void MX_GPIO_Init(void);
static void MX_DMA_Init(void);
static void MX_USART2_UART_Init(void);
static void MX_ADC1_Init(void);
static void MX_RTC_Init(void);
static void MX_USART1_UART_Init(void);
static void MX_USART6_UART_Init(void);
static void MX_I2C1_Init(void);
static void MX_USART3_UART_Init(void);
#define RTC_BACKUP_MAGIC  0x32F2U
/* USER CODE BEGIN PFP */
/* USER CODE BEGIN PFP */

void Debug_Print(const char *text);

/* USER CODE END PFP */
/* USER CODE END PFP */

/* Private user code ---------------------------------------------------------*/
/* USER CODE BEGIN 0 */
//temperature config
void uart_init (uint32_t baud)
{
	 huart1.Instance = USART1;
	  huart1.Init.BaudRate = baud;
	  huart1.Init.WordLength = UART_WORDLENGTH_8B;
	  huart1.Init.StopBits = UART_STOPBITS_1;
	  huart1.Init.Parity = UART_PARITY_NONE;
	  huart1.Init.Mode = UART_MODE_TX_RX;
	  huart1.Init.HwFlowCtl = UART_HWCONTROL_NONE;
	  huart1.Init.OverSampling = UART_OVERSAMPLING_16;
	  if (HAL_HalfDuplex_Init(&huart1) != HAL_OK)
	  {
	    Error_Handler();
	  }

}
int DS18B20_Start(void)
{
	uint8_t data = 0xF0;
	uart_init(9600);
	HAL_UART_Transmit(&huart1, &data, 1, 100);  // low for 500+ms
	if (HAL_UART_Receive(&huart1, &data, 1, 1000) != HAL_OK) return -1;   // failed.. check connection
	uart_init(115200);
	if (data == 0xF0) return -2;  // no response.. check connection
	return 1;  // response detected
}

void DS18B20_Write (uint8_t data)
{
  uint8_t buffer[8];
  for (int i=0; i<8; i++)
  {
    if ((data & (1<<i))!=0)  // if the bit is high
    {
	buffer[i] = 0xFF;  // write 1
    }
    else  // if the bit is low
    {
	buffer[i] = 0;  // write 0
    }
  }
  HAL_UART_Transmit(&huart1, buffer, 8, 100);
}
uint8_t DS18B20_Read (void)
{
	uint8_t buffer[8];
	uint8_t value = 0;
	for (int i=0; i<8; i++)
	{
		buffer[i] = 0xFF;
	}
	//isRxed = 0;
	HAL_UART_Transmit_DMA(&huart1, buffer, 8);
	HAL_UART_Receive_DMA(&huart1, RxData, 8);

	while (isRxed == 0);
	for (int i=0;i<8;i++)
	{
		if (RxData[i]==0xFF)  // if the pin is HIGH
		{
			value |= 1<<i;  // read = 1
		}
	}
	isRxed = 0;
	return value;
}
void HAL_UART_RxCpltCallback(UART_HandleTypeDef *huart)
{
    if (huart->Instance == USART1)
    {
        isRxed = 1;   // DS18B20 over USART1
    }

    else if (huart->Instance == USART6)
    {
        if (rxByteBuf == '\n' || rxByteBuf == '\r')
        {
            if (rxLineIdx > 0)
            {
                rxLineBuf[rxLineIdx] = '\0';
                strncpy((char*)lineComplete, (char*)rxLineBuf, UART6_RX_BUF_SIZE);
                lineComplete[UART6_RX_BUF_SIZE - 1] = '\0';
                lineReady = 1;
                rxLineIdx = 0;
            }
        }
        else
        {
            if  (rxLineIdx < UART6_RX_BUF_SIZE - 1)
            {
                rxLineBuf[rxLineIdx++] = rxByteBuf;
            }
            else
            {
                rxLineIdx = 0;
            }
        }

        HAL_UART_Receive_IT(&huart6, &rxByteBuf, 1);
    }
}



//adc config
uint16_t ADC_conv_rank1 (void){

	  ADC_ChannelConfTypeDef sConfig = {0};

	sConfig.Channel = ADC_CHANNEL_4;
	  sConfig.Rank = 1;
	  sConfig.SamplingTime = ADC_SAMPLETIME_480CYCLES;
	  if (HAL_ADC_ConfigChannel(&hadc1, &sConfig) != HAL_OK)
	  {
	    Error_Handler();
	  }
	  HAL_ADC_Start(&hadc1);
	 			  		 	  	 	 	 	        HAL_ADC_PollForConversion(&hadc1, 100);
	 			  		 	  	 	 	 	        uint16_t adcval = HAL_ADC_GetValue(&hadc1);
	 			  		 	  	 	 	 	 HAL_ADC_Stop(&hadc1);
return adcval;
}
uint16_t ADC_conv_rank2 (void){

	  ADC_ChannelConfTypeDef sConfig = {0};

	sConfig.Channel = ADC_CHANNEL_5;
	  sConfig.Rank = 1;
	  sConfig.SamplingTime = ADC_SAMPLETIME_480CYCLES;
	  if (HAL_ADC_ConfigChannel(&hadc1, &sConfig) != HAL_OK)
	  {
	    Error_Handler();
	  }
	  HAL_ADC_Start(&hadc1);
	 			  		 	  	 	 	 	        HAL_ADC_PollForConversion(&hadc1, 100);
	 			  		 	  	 	 	 	        uint16_t adcval = HAL_ADC_GetValue(&hadc1);
	 			  		 	  	 	 	 	 HAL_ADC_Stop(&hadc1);
return adcval;
}
uint16_t ADC_conv_rank3 (void){

	  ADC_ChannelConfTypeDef sConfig = {0};

	sConfig.Channel = ADC_CHANNEL_6;
	  sConfig.Rank = 1;
	  sConfig.SamplingTime = ADC_SAMPLETIME_3CYCLES;
	  if (HAL_ADC_ConfigChannel(&hadc1, &sConfig) != HAL_OK)
	  {
	    Error_Handler();
	  }
	  HAL_ADC_Start(&hadc1);
	 			  		 	  	 	 	 	        HAL_ADC_PollForConversion(&hadc1, 100);
	 			  		 	  	 	 	 	        uint16_t adcval = HAL_ADC_GetValue(&hadc1);
	 			  		 	  	 	 	 	 HAL_ADC_Stop(&hadc1);
return adcval;
}
void HAL_RTCEx_WakeUpTimerEventCallback(RTC_HandleTypeDef *hrtc)
{
    if (temp_counter > 0) {
        temp_counter--;
        if (temp_counter == 0) {
            trigger_temp = 1;
            temp_counter = temp_delay_minutes;

        }
    }
    if (ph_counter > 0) {
        ph_counter--;
        if (ph_counter == 0) {
            trigger_ph = 1;
            ph_counter = ph_delay_minutes;

        }
    }
    if (tur_counter > 0) {
           tur_counter--;
           if (tur_counter == 0) {
               trigger_tur = 1;
               tur_counter = tur_delay_minutes;

           }
       }
    if (con_counter > 0) {
           con_counter--;
           if (con_counter == 0) {
               trigger_con = 1;
               con_counter = con_delay_minutes;

           }
       }
}
float EC_ReadVoltage(void)
{
    uint16_t adc = ADC_conv_rank3();

    float voltage = ((float)adc * 3.3f) / 4095.0f;
    return voltage;
}
/* ═══════════════════════════════════════════════════════════════════════════
 *  UART6 – RÉCEPTION (mode interruption, octet par octet)
 * ═══════════════════════════════════════════════════════════════════════════ */
static void UART6_StartReceive(void)
{
    HAL_UART_Receive_IT(&huart6, &rxByteBuf, 1);
}
static void ProcessRxLine(const char *line)
{
	if (strncmp(line, "SET_EC_DELAY:", 13) == 0)
	{
	    long val = atol(line + 13);
	    if (val > 0 && val <= 2880)
	    {
	        con_delay_minutes = val;
	        con_counter = con_delay_minutes;
	    }
	    return;
	}

	if (strncmp(line, "SET_PH_DELAY:", 13) == 0)
	{
	    long val = atol(line + 13);
	    if (val > 0 && val <= 2880)
	    {
	        ph_delay_minutes = val;
	        ph_counter = ph_delay_minutes;
	    }
	    return;
	}

	if (strncmp(line, "SET_TEMP_DELAY:", 15) == 0)
	{
	    long val = atol(line + 15);
	    if (val > 0 && val <= 2880)
	    {
	        temp_delay_minutes = val;
	        temp_counter = temp_delay_minutes;
	    }
	    return;
	}

	if (strncmp(line, "SET_TURB_DELAY:", 15) == 0)
	{
	    long val = atol(line + 15);
	    if (val > 0 && val <= 2880)
	    {
	        tur_delay_minutes = val;
	        tur_counter = tur_delay_minutes;
	        HAL_UART_Transmit(&huart2, (uint8_t*)"tru update\r\n", 18, 300);
	    }
	    return;
	}

	if (strcmp(line, "ENTERPH") == 0 || strcmp(line, "CALPH") == 0 || strcmp(line, "EXITPH") == 0)
	{
	    float voltage_mv = ((float)ADC_conv_rank2() * 3300.0f) / 4095.0f;

	    char cmd[16];
	    strncpy(cmd, line, sizeof(cmd));
	    cmd[sizeof(cmd) - 1] = '\0';

	    DFRobot_PH_calibration_cmd_uart(&ph_sensor, voltage_mv, Temperature, cmd, &huart2);

	   // HAL_UART_Transmit(&huart2, (uint8_t*)"pH command received\r\n", 21, 300);

	    return;
	}

    if (strcmp(line, "ENTEREC") == 0)
    {
        ec_calibration_mode = 1;
        HAL_UART_Transmit(&huart2, (uint8_t*)"EC calibration mode ON\r\n", 24, 300);
        HD44780_SetCursor(0, 0);
                                                                    HD44780_PrintStr(">EC calibration mode ON");
        return;
    }

    if (strncmp(line, "CALEC1:", 7) == 0)
    {
        ec_cal_point1 = atof(line + 7);
        ec_voltage1 = EC_ReadVoltage();
        ec_has_point1 = 1;

        HAL_UART_Transmit(&huart2, (uint8_t*)"EC point 1 saved\r\n", 18, 300);
        HD44780_SetCursor(0, 0);
                                                                    HD44780_PrintStr(">EC point 1 saved<");
        return;
    }

    if (strncmp(line, "CALEC2:", 7) == 0)
    {
        ec_cal_point2 = atof(line + 7);
        ec_voltage2 = EC_ReadVoltage();
        ec_has_point2 = 1;

        HAL_UART_Transmit(&huart2, (uint8_t*)"EC point 2 saved\r\n", 18, 300);
        HD44780_SetCursor(0, 0);
                                                                    HD44780_PrintStr("EC point 2 saved<");
        return;
    }

    if (strcmp(line, "EXITEC") == 0)
    {
        if (ec_has_point1 && ec_has_point2 && fabsf(ec_voltage2 - ec_voltage1) > 0.01f)
        {
            ec_slope = (ec_cal_point2 - ec_cal_point1) / (ec_voltage2 - ec_voltage1);
            ec_offset = ec_cal_point1 - ec_slope * ec_voltage1;

            HAL_UART_Transmit(&huart2, (uint8_t*)"EC calibration successful\r\n", 27, 300);
            HD44780_SetCursor(0, 0);
                                                                        HD44780_PrintStr(">calibration successful<");
        }
        else
        {
            HAL_UART_Transmit(&huart2, (uint8_t*)"EC calibration failed\r\n", 23, 300);
            HD44780_SetCursor(0, 0);
                                                                                   HD44780_PrintStr("calibration failed");
        }

        ec_calibration_mode = 0;
        return;
    }

    if (strcmp(line, "gsm==1") == 0)
    {
        gsm=1;
        return;


    }
    if (strcmp(line, "gsm==0") == 0)
       {
           gsm=0;
           return;

       }



    // ==========================================
    // GSM_COUNT
    // Exemple : GSM_COUNT:2
    // ==========================================
    if (strncmp(line, "GSM_COUNT:", 10) == 0)
    {
        int count = atoi(line + 10);

        if (count >= 0 && count <= MAX_GSM_NUMBERS)
        {
            gsm_number_count = (uint8_t)count;

            for (int i = 0; i < MAX_GSM_NUMBERS; i++)
            {
                phoneNumbers[i][0] = '\0';
            }

            Debug_Print("GSM_COUNT updated\r\n");
        }
        else
        {
            Debug_Print("GSM_COUNT error\r\n");
        }

        return;
    }


    // ==========================================
    // GSM_NUM
    // Exemple : GSM_NUM:0:+21650610318
    // ==========================================
    if (strncmp(line, "GSM_NUM:", 8) == 0)
    {
        const char *data = line + 8;

        // data = "0:+21650610318"
        const char *separator = strchr(data, ':');

        if (separator == NULL)
        {
            Debug_Print("GSM_NUM format error\r\n");
            return;
        }

        int index = atoi(data);

        if (index < 0 || index >= MAX_GSM_NUMBERS)
        {
            Debug_Print("GSM_NUM index error\r\n");
            return;
        }

        const char *number = separator + 1;

        if (strlen(number) == 0 ||
            strlen(number) >= GSM_NUMBER_LENGTH)
        {
            Debug_Print("GSM_NUM number error\r\n");
            return;
        }

        strncpy(
            phoneNumbers[index],
            number,
            GSM_NUMBER_LENGTH - 1
        );

        phoneNumbers[index][GSM_NUMBER_LENGTH - 1] = '\0';

        Debug_Print("GSM number received: ");
        Debug_Print(phoneNumbers[index]);
        Debug_Print("\r\n");

        return;
    }
        // ======================================
        // Extraire index
        // ======================================

        char indexString[4];

        memset(indexString, 0, sizeof(indexString));



}

void Debug_Print(const char *text)
{
    HAL_UART_Transmit(
        &huart2,
        (uint8_t *)text,
        strlen(text),
        1000
    );
}
/* Send AT command to GSM module */
/* Send an AT command followed by carriage return */
void GSM_SendCommand(const char *command)
{
    Debug_Print("\r\nSTM32 -> GSM: ");
    Debug_Print(command);
    Debug_Print("\r\n");

    HAL_UART_Transmit(
        &huart3,
        (uint8_t *)command,
        strlen(command),
        1000
    );

    uint8_t carriageReturn = '\r';

    HAL_UART_Transmit(
        &huart3,
        &carriageReturn,
        1,
        100
    );
}

/* Receive response from SIM800L */
void GSM_ReceiveResponse(char *buffer,
                         uint16_t size,
                         uint32_t timeout)
{
    uint32_t startTime = HAL_GetTick();
    uint16_t index = 0;
    uint8_t c;

    memset(buffer, 0, size);

    Debug_Print("\r\n--- GSM RESPONSE ---\r\n");

    while ((HAL_GetTick() - startTime) < timeout &&
           index < size - 1)
    {
        if (HAL_UART_Receive(&huart3, &c, 1, 20) == HAL_OK)
        {
            buffer[index++] = (char)c;
            buffer[index] = '\0';

            /* Immediately send received character to the computer */
            HAL_UART_Transmit(&huart2, &c, 1, 100);

            if (strstr(buffer, "\r\nOK\r\n") != NULL || strstr(buffer, "\r\nERROR\r\n") != NULL)
            {
                break;
            }
        }
    }

    buffer[index] = '\0';

    Debug_Print("\r\n--- END RESPONSE ---\r\n");
}


/* Send command and check expected response */
bool GSM_SendCommandWithResponse(const char *command,
                                 const char *expectedResponse,
                                 uint32_t timeout)
{
    char buffer[256];

    GSM_SendCommand(command);
    GSM_ReceiveResponse(buffer, sizeof(buffer), timeout);

    return strstr(buffer, expectedResponse) != NULL;
}


/* Wait for the > prompt after AT+CMGS */
bool GSM_WaitForPrompt(uint32_t timeout)
{
    uint32_t startTime = HAL_GetTick();
    uint8_t c;

    while ((HAL_GetTick() - startTime) < timeout)
    {
        if (HAL_UART_Receive(&huart3, &c, 1, 20) == HAL_OK)
        {
            if (c == '>')
            {
                return true;
            }

            /* Stop if SIM800L returns an error */
            if (c == '\0')
            {
                continue;
            }
        }
    }

    return false;
}


bool GSM_Init(void)
{
    char buffer[256];
    bool moduleDetected = false;
    bool registered = false;

    /* Give SIM800L time to start */
    HAL_Delay(5000);

    /* Check communication */
    for (int i = 0; i < 5; i++)
    {
        if (GSM_SendCommandWithResponse("AT", "OK", 2000))
        {
            moduleDetected = true;
            break;
        }

        HAL_Delay(1000);
    }

    if (!moduleDetected)
    {
        return false;
    }

    /* Disable command echo */
  //  GSM_SendCommandWithResponse("ATE0", "OK", 2000);

    /* Check SIM card */

    /* Wait up to approximately 60 seconds for network registration */
    for (int i = 0; i < 60; i++)
    {
        GSM_SendCommand("AT+CREG?");
        GSM_ReceiveResponse(buffer, sizeof(buffer), 2000);

        /*
         * ,1 = registered on home network
         * ,5 = registered while roaming
         */
        if (strstr(buffer, ",1") != NULL ||
            strstr(buffer, ",5") != NULL)
        {
            registered = true;
            break;
        }

        HAL_Delay(1000);
    }

    if (!registered)
    {
        return false;
    }

    /* Check signal quality */
    GSM_SendCommand("AT+CSQ");
    GSM_ReceiveResponse(buffer, sizeof(buffer), 2000);

    /* Enable text-mode SMS */
    if (!GSM_SendCommandWithResponse("AT+CMGF=1", "OK", 2000))
    {
        return false;
    }

    return true;
}


bool GSM_SendSMS(const char *number, const char *message)
{
    char command[64];
    char response[256];

    if (number == NULL || message == NULL)
    {
        Debug_Print("Numero ou message NULL\r\n");
        return false;
    }

    /* Mode SMS texte */
    if (!GSM_SendCommandWithResponse(
            "AT+CMGF=1",
            "OK",
            3000))
    {
        Debug_Print("Erreur AT+CMGF\r\n");
        return false;
    }

    /*
     * BUG CORRIGE :
     * attendre OK apres AT+CSMP avant AT+CMGS.
     */
    if (!GSM_SendCommandWithResponse(
            "AT+CSMP=17,167,0,0",
            "OK",
            3000))
    {
        Debug_Print("Erreur AT+CSMP\r\n");
        return false;
    }

    snprintf(command,
             sizeof(command),
             "AT+CMGS=\"%s\"",
             number);

    GSM_SendCommand(command);

    /* Attendre le prompt de saisie du SMS */
    if (!GSM_WaitForPrompt(10000))
    {
        Debug_Print("Prompt > non recu\r\n");
        return false;
    }

    /* Envoyer le contenu */
    if (HAL_UART_Transmit(
            &huart3,
            (uint8_t *)message,
            strlen(message),
            5000) != HAL_OK)
    {
        Debug_Print("Erreur UART pendant le message\r\n");
        return false;
    }

    /* Ctrl+Z termine et valide le SMS */
    uint8_t ctrlZ = 0x1A;

    if (HAL_UART_Transmit(
            &huart3,
            &ctrlZ,
            1,
            1000) != HAL_OK)
    {
        Debug_Print("Erreur UART Ctrl+Z\r\n");
        return false;
    }

    /*
     * Ne pas faire HAL_Delay(100) ici :
     * commencer immédiatement à recevoir la réponse.
     */
    GSM_ReceiveResponse(
        response,
        sizeof(response),
        60000
    );

    if (strstr(response, "+CMGS:") != NULL &&
        strstr(response, "OK") != NULL)
    {
        return true;
    }

    if (strstr(response, "+CMS ERROR:") != NULL)
    {
        Debug_Print("Le reseau GSM a refuse le SMS\r\n");
    }
    else if (strstr(response, "ERROR") != NULL)
    {
        Debug_Print("Le SIM800L a retourne ERROR\r\n");
    }
    else
    {
        Debug_Print("Timeout : aucune confirmation +CMGS\r\n");
    }

    return false;
}
bool GSM_SendSMS_ToMultipleNumbers(
    char numbers[][GSM_NUMBER_LENGTH],
    uint8_t numberCount,
    const char *message)
{
    bool allSent = true;

    for (uint8_t i = 0; i < numberCount; i++)
    {
        // Ne pas envoyer vers une case vide
        if (numbers[i][0] == '\0')
        {
            continue;
        }

        Debug_Print("\r\nEnvoi vers : ");
        Debug_Print(numbers[i]);
        Debug_Print("\r\n");

        if (!GSM_SendSMS(numbers[i], message))
        {
            Debug_Print("Echec d'envoi\r\n");
            allSent = false;
        }
        else
        {
            Debug_Print("SMS envoye avec succes\r\n");
        }

        HAL_Delay(3000);
    }

    return allSent;
}
/* USER CODE END 0 */

/**
  * @brief  The application entry point.
  * @retval int
  */
int main(void)
{

  /* USER CODE BEGIN 1 */

  /* USER CODE END 1 */

  /* MCU Configuration--------------------------------------------------------*/

  /* Reset of all peripherals, Initializes the Flash interface and the Systick. */
  HAL_Init();

  /* USER CODE BEGIN Init */

  /* USER CODE END Init */

  /* Configure the system clock */
  SystemClock_Config();

  /* USER CODE BEGIN SysInit */

  /* USER CODE END SysInit */

  /* Initialize all configured peripherals */
  MX_GPIO_Init();
  MX_DMA_Init();
  MX_USART2_UART_Init();
  MX_ADC1_Init();
  MX_RTC_Init();
  MX_USART1_UART_Init();
  MX_USART6_UART_Init();
  MX_I2C1_Init();
  MX_USART3_UART_Init();
  /* USER CODE BEGIN 2 */
  DFRobot_PH_init(&ph_sensor);
  UART6_StartReceive();
  HD44780_Init(2);
  bool gsmReady = GSM_Init();
  /* SMS anti-spam state: one SMS per abnormal episode. */
   const uint32_t SMS_RETRY_DELAY_MS =  120UL * 1000UL;

   bool temperatureAlertSent = false;
   bool phAlertSent = false;
   bool conAlertSent = false;
   bool turAlertSent = false;

   uint32_t temperatureLastSmsAttempt = 0U;
   uint32_t phLastSmsAttempt = 0U;
   uint32_t conLastSmsAttempt = 0U;
   uint32_t turLastSmsAttempt = 0U;


   uint8_t phoneCount =
       sizeof(phoneNumbers) / sizeof(phoneNumbers[0]);
   // Fires every 60 seconds (counter + 1)
   HAL_RTCEx_SetWakeUpTimer_IT(&hrtc, 59, RTC_WAKEUPCLOCK_CK_SPRE_16BITS);
   /* USER CODE END 2 */

   /* Infinite loop */
   /* USER CODE BEGIN WHILE */
   while (1)
   {RTC_TimeTypeDef sTime = {0};
   RTC_DateTypeDef sDate = {0};

     /* USER CODE END WHILE */

     /* USER CODE BEGIN 3 */
 	  HAL_RTC_GetTime(&hrtc, &sTime, RTC_FORMAT_BIN);
 	  HAL_RTC_GetDate(&hrtc, &sDate, RTC_FORMAT_BIN);


 	if (trigger_temp == 1){
 	  presence = DS18B20_Start();
 				  		 	  	 	 	 	  	     if (presence == 1) {  // ✅ Vérifier que le capteur répond
 				  		 	  	 	 	 	  	       DS18B20_Write(0xCC);  // Skip ROM

 				  		 	  	 	 	 	  	      DS18B20_Write(0x44);  // Start conversion
 				  		 	  	 	 	 	  	       HAL_Delay(750);       // ✅ IMPORTANT : attendre la conversion

 				  		 	  	 	 	 	  	       presence = DS18B20_Start();
 				  		 	  	 	 	 	  	       DS18B20_Write(0xCC);  // Skip ROM
 				  		 	  	 	 	 	  	       DS18B20_Write(0xBE);  // Read Scratchpad

 				  		 	  	 	 	 	  	       Temp_LSB = DS18B20_Read();
 				  		 	  	 	 	 	  	       Temp_MSB = DS18B20_Read();
 				  		 	  	 	 	 	  	       Temp = ((Temp_MSB << 8)) | Temp_LSB;
 				  		 	  	 	 	 	  	     Temperature = (float)Temp / 16.0;

 				  		 	  	 	 	 	  	       // Afficher la température
 				  		 	  	 	 	 	  	     int t_int = (int)Temperature;
 				  		 	  	 	 	 	  	     int t_dec = (int)((Temperature - t_int) * 1000);
 				  		 	  	 	 	 	 sprintf(tempStr, "T:%d.%03d, Time: %02d:%02d, Date: %02d/%02d/%04d\r\n",
 				  		 	  	 	 	 	                     t_int, t_dec,
 				  		 	  	 	 	 	                     sTime.Hours, sTime.Minutes,
 				  		 	  	 	 	 	                     sDate.Date, sDate.Month, sDate.Year + 2000);

 				  		 	  	 	 	 	  HAL_UART_Transmit(&huart2, (uint8_t*)tempStr, strlen(tempStr), 300);
 				  		 	  	 	 	HAL_UART_Transmit(&huart6, (uint8_t*)tempStr, strlen(tempStr), 300);
 				  		 	  	 	HAL_Delay(100);
 				  		 	  	 	 	 	  trigger_temp=0;
         bool temperatureOutOfRange = (Temperature > 18.0f);

         if (temperatureOutOfRange &&
             !temperatureAlertSent &&
             (temperatureLastSmsAttempt == 0U ||
              (HAL_GetTick() - temperatureLastSmsAttempt) >= SMS_RETRY_DELAY_MS))
         {
             temperatureLastSmsAttempt = HAL_GetTick();

             if (gsmReady && gsm==1)
             {
                 char smsMessage[90];
                 snprintf(smsMessage,
                          sizeof(smsMessage),
                          "Alerte : temperature trop elevee [10-18] (%.2f C)",
                          Temperature);

                 bool smsSent = GSM_SendSMS_ToMultipleNumbers(
                     phoneNumbers,
                     phoneCount,
                     smsMessage
                 );

                 if (smsSent)
                 {
                   //  temperatureAlertSent = true;
                     Debug_Print("\r\nAlerte temperature envoyee une seule fois\r\n");
                 }
                 else
                 {
                     Debug_Print("\r\nEchec SMS temperature - nouvel essai dans 15 min\r\n");
                 }
             }
             else
             {
                 Debug_Print("\r\nModule GSM non disponible - nouvel essai dans 15 min\r\n");
             }
         }

         /* Hysteresis: rearm only after a clear return below 17 C. */
         if (Temperature < 17.0f)
         {

             temperatureAlertSent = false;
             temperatureLastSmsAttempt = 0U;
         }

 				  		 	  	 	 	HAL_Delay(1000);}}

 if(trigger_tur == 1){
 				  		 	  	 	 	 	  	     //get the value
 				  		 	  	 	 	 	 ADC_VAL[0] = ADC_conv_rank1();


 				  		 	  	 	 	 	 // 1. Convert ADC to real voltage (3.3V ref, 12-bit)
 				  		 	  	 	 	 	 			  		 	  	 	 	 	float voltage_V = (ADC_VAL[0] * 3.3f) / 4095.0f;

 				  		 	  	 	 	 	 			  		 	  	 	 	 	// 2. Compensate for voltage divider R1=10k R2=4.7k
 				  		 	  	 	 	 	 			  		 	  	 	 	 	voltage_V = voltage_V * (10000.0f + 4700.0f) / 4700.0f;

 				  		 	  	 	 	 	 			  		 	  	 	 	 	// 3. Calculate NTU
 				  		 	  	 	 	 	 			  		 	  	 	 	 	float ntu = -1120.4f * voltage_V * voltage_V
 				  		 	  	 	 	 	 			  		 	  	 	 	 	           + 5742.3f  * voltage_V
 				  		 	  	 	 	 	 			  		 	  	 	 	 	           - 4352.9f;

 				  		 	  	 	 	 	 			  		 	  	 	 	 	// 4. ✅ INVERT HERE
 				  		 	  	 	 	 	 			  		 	  	 	 	 	ntu = 3000.0f - ntu;

 				  		 	  	 	 	 	 			  		 	  	 	 	 	// 5. Clamp between 0 and 3000
 				  		 	  	 	 	 	 			  		 	  	 	 	 	if (ntu < 0.0f)    ntu = 0.0f;
 				  		 	  	 	 	 	 			  		 	  	 	 	 	if (ntu > 3000.0f) ntu = 3000.0f;

 				  		 	  	 	 	 	 			  		 	  	 	 	 	// 6. Display



 				  		 	  	 	 	 	 			  		 	  	 		  		 sprintf(debug, "Turb=%.2f NTU ,Time: %02d:%02d, Date: %02d/%02d/%04d \r\n",
 				  		 	  	 	 	 	 			  		 	  	 		  			            ntu,
 														  		 	  	 	 	 	                     sTime.Hours, sTime.Minutes,
 														  		 	  	 	 	 	                     sDate.Date, sDate.Month, sDate.Year + 2000);
 				  		 	  	 	 	 	 			  		 	  	 		  			    HAL_UART_Transmit(&huart2, (uint8_t*)debug, strlen(debug), 300);
 				  		 	  	 	 	 	 			  		 	  	 		 HAL_UART_Transmit(&huart6, (uint8_t*)debug, strlen(debug), 300);
 				  		 	  	 	 	 	 			  		 	 HAL_Delay(2000);
         bool turOutOfRange = (ntu > 100.0f);

         if (turOutOfRange &&
             !turAlertSent &&
             (turLastSmsAttempt == 0U ||
              (HAL_GetTick() - turLastSmsAttempt) >= SMS_RETRY_DELAY_MS))
         {
             turLastSmsAttempt = HAL_GetTick();

             if (gsmReady && gsm)
             {
                 char smsMessage[90];
                 snprintf(smsMessage,
                          sizeof(smsMessage),
                          "Alerte : eau trouble >100(%.1f NTU)",
                          ntu);

                 bool smsSent = GSM_SendSMS_ToMultipleNumbers(
                     phoneNumbers,
                     phoneCount,
                     smsMessage
                 );

                 if (smsSent)
                 {
                     /* Important: use turAlertSent, not temperatureAlertSent. */
                    // turAlertSent = true;
                     Debug_Print("\r\nAlerte turbidite envoyee une seule fois\r\n");
                 }
                 else
                 {
                     Debug_Print("\r\nEchec SMS turbidite - nouvel essai dans 15 min\r\n");
                 }
             }
             else
             {
                 Debug_Print("\r\nModule GSM non disponible - nouvel essai dans 15 min\r\n");
             }
         }

         /* Hysteresis: do not rearm around the 100 NTU boundary. */
         if (ntu < 80.0f)
         {
            turAlertSent = false;
             turLastSmsAttempt = 0U;
             turLastSmsAttempt = HAL_GetTick();

                         if (gsmReady && gsm)
                         {
                             char smsMessage[90];
                             snprintf(smsMessage,
                                      sizeof(smsMessage),
                                      "Alerte : eau trouble >100(%.1f NTU)",
                                      ntu);

                             bool smsSent = GSM_SendSMS_ToMultipleNumbers(
                                 phoneNumbers,
                                 phoneCount,
                                 smsMessage
                             );

         }}

 				  		 	  	 	 	 	 			  					  		 	  	 	 	HAL_Delay(1000);}				  		 	  	 	 	 	 			  		 	  	 		 trigger_tur = 0;

   if(trigger_ph == 1){
   				  		 	  	 	 	 	  	     //get the value

   				  		 	  	 	 	 	     ADC_VAL[1] = ADC_conv_rank2();



   				  		 	  	 	 	float voltage_mv = (ADC_VAL[1] * 3300.0f) / 4095.0f;
   				  		 	  	 	 	 	 			  		 	  	 	 	 	      // FIXED pH calculation - correct voltage + real temperature
   				  		 	  	 	 	 	 			  		 	  	 	 	 	      float pH = DFRobot_PH_readPH(&ph_sensor, voltage_mv, Temperature);   // ← was the main bug!
   				  		 	  	 	 	 	 			  		 	  	 	 	 	      int ph_int = (int)pH;
   				  		 	  	 	 	 	 			  		 	  	 	 	 	      int ph_dec = (int)((pH - ph_int) * 10);
   				  		 	  	 	 	 	 			  		 	  	 	 	 	      sprintf(phStr, "ph:%d.%d ", ph_int, ph_dec);
   				  		 	  	 	 	 	 			  		 	  	 	char debugph[300];
   				  		 	  	 	 	 	 			  		 	  	 		  		 sprintf(debugph, "pH=%.2f Time: %02d:%02d, Date: %02d/%02d/%04d \r\n",
   				  		 	  	 	 	 	 			  		 	  	 		  			              pH,
 															  		 	  	 	 	 	                     sTime.Hours, sTime.Minutes,
 															  		 	  	 	 	 	                     sDate.Date, sDate.Month, sDate.Year + 2000);
   				  		 	  	 	 	 	 			  		 	  	 		  			    HAL_UART_Transmit(&huart2, (uint8_t*)debugph, strlen(debugph), 300);
   				  		 	  	 	 	 	 			  		 	  	 		 HAL_UART_Transmit(&huart6, (uint8_t*)debugph, strlen(debugph), 300);
   				  		 	  	 	 	 	 			  		 	HAL_Delay(1000);
         bool phOutOfRange = (pH > 9.0f) || (pH < 7.5f);

         if (phOutOfRange &&
             !phAlertSent &&
             (phLastSmsAttempt == 0U ||
              (HAL_GetTick() - phLastSmsAttempt) >= SMS_RETRY_DELAY_MS))
         {
             phLastSmsAttempt = HAL_GetTick();

             if (gsmReady && gsm==1)
             {
                 char smsMessage[80];
                 snprintf(smsMessage,
                          sizeof(smsMessage),
                          "Alerte : pH hors norme [7.5-9] (%.2f)",
                          pH);

                 bool smsSent = GSM_SendSMS_ToMultipleNumbers(
                     phoneNumbers,
                     phoneCount,
                     smsMessage
                 );

                 if (smsSent)
                 {
                     //phAlertSent = true;
                     Debug_Print("\r\nAlerte pH envoyee une seule fois\r\n");
                 }
                 else
                 {
                     Debug_Print("\r\nEchec SMS pH - nouvel essai dans 15 min\r\n");
                 }
             }
             else
             {
                 Debug_Print("\r\nModule GSM non disponible - nouvel essai dans 15 min\r\n");
             }
         }

         /* Hysteresis: the pH must return clearly inside the normal zone. */
         if ((pH >= 7.6f) && (pH <= 8.9f))
         {
             phAlertSent = false;
             phLastSmsAttempt = 0U;
         }

   				  		 	  	 	 	 	 			 trigger_ph = 0;
   				  		 	  	 	 	 	 			 				  		 	  	 	 	HAL_Delay(1000);} 				  		 	  	 	 	 	 			  		 	  	 		 trigger_ph = 0;

 if(trigger_con == 1){
 				  		 	  	 	 	 	  	     //get the value

 				  		 	  	 	 	 	     ADC_VAL[2] = ADC_conv_rank3();



 				  		 	  	 	 	 	     float tension =  (ADC_VAL[2] * 3.3f) / 4095.0f;
 				  		 	  	 	 	 	 			  		 	  	 	  float estimationMS = tension * 0.993 * 2.0;

 				  		 	  	 	 	 	 			  		char debugec[200];
 				  		 	  	 	 	 	 			  		 	  	 		  		 sprintf(debugec, "EC=%.1f Time: %02d:%02d, Date: %02d/%02d/%04d\r\n",
 				  		 	  	 	 	 	 			  		 	  	 		  			             estimationMS,
 														  		 	  	 	 	 	                     sTime.Hours, sTime.Minutes,
 														  		 	  	 	 	 	                     sDate.Date, sDate.Month, sDate.Year + 2000);
 				  		 	  	 	 	 	 			  		 	  	 		  			    HAL_UART_Transmit(&huart2, (uint8_t*)debugec, strlen(debugec), 300);
 				  		 	  	 	 	 	 			  		 	  	 		 HAL_UART_Transmit(&huart6, (uint8_t*)debugec, strlen(debugec), 300);
 				  		 	  	 	 	 	 			  		 	 HAL_Delay(1000);
 				  		 	  	 	 	 	 			  		 	  	 		 trigger_con = 0;
         bool conOutOfRange = (estimationMS > 3.0f);

         /* Anti-spam: one successful SMS per abnormal episode.
          * If sending fails, retry only after SMS_RETRY_DELAY_MS.
          */
         if (conOutOfRange &&
             !conAlertSent &&
             (conLastSmsAttempt == 0U ||
              (HAL_GetTick() - conLastSmsAttempt) >= SMS_RETRY_DELAY_MS))
         {
             conLastSmsAttempt = HAL_GetTick();

             if (gsmReady)
             {
                 char smsMessage[100];
                 snprintf(smsMessage,
                          sizeof(smsMessage),
                          "Alerte : conductivite trop elevee>3mS/cm (%.1f mS/cm)",
                          estimationMS);

                 bool smsSent = GSM_SendSMS_ToMultipleNumbers(
                		 phoneNumbers,
                     phoneCount,
                     smsMessage
                 );

                 if (smsSent)
                 {
                   //  conAlertSent = true;
                     Debug_Print("\r\nAlerte conductivite envoyee une seule fois\r\n");
                 }
                 else
                 {
                     Debug_Print("\r\nEchec SMS conductivite - nouvel essai dans 15 min\r\n");
                 }
             }
             else
             {
                 Debug_Print("\r\nModule GSM non disponible - nouvel essai dans 15 min\r\n");
             }
         }

         /* Hysteresis: rearm only below 2.8 mS/cm. */
         if (estimationMS < 2.8f)
         {
             conAlertSent = false;
             conLastSmsAttempt = 0U;
         }

 				  		 	  	 	 	 	 			  		 	 				  		 	  	 	 	HAL_Delay(1000);}
 if (lineReady)
 {
     lineReady = 0;
     ProcessRxLine((char*)lineComplete);
 }
 }

 }



  /* USER CODE END 3 */


/**
  * @brief System Clock Configuration
  * @retval None
  */
void SystemClock_Config(void)
{
  RCC_OscInitTypeDef RCC_OscInitStruct = {0};
  RCC_ClkInitTypeDef RCC_ClkInitStruct = {0};

  /** Configure the main internal regulator output voltage
  */
  __HAL_RCC_PWR_CLK_ENABLE();
  __HAL_PWR_VOLTAGESCALING_CONFIG(PWR_REGULATOR_VOLTAGE_SCALE3);

  /** Initializes the RCC Oscillators according to the specified parameters
  * in the RCC_OscInitTypeDef structure.
  */
  RCC_OscInitStruct.OscillatorType = RCC_OSCILLATORTYPE_HSI|RCC_OSCILLATORTYPE_LSI;
  RCC_OscInitStruct.LSEState = RCC_LSE_ON;
  RCC_OscInitStruct.HSIState = RCC_HSI_ON;
  RCC_OscInitStruct.HSICalibrationValue = RCC_HSICALIBRATION_DEFAULT;
  RCC_OscInitStruct.LSIState = RCC_LSI_ON;
  RCC_OscInitStruct.PLL.PLLState = RCC_PLL_ON;
  RCC_OscInitStruct.PLL.PLLSource = RCC_PLLSOURCE_HSI;
  RCC_OscInitStruct.PLL.PLLM = 8;
  RCC_OscInitStruct.PLL.PLLN = 60;
  RCC_OscInitStruct.PLL.PLLP = RCC_PLLP_DIV2;
  RCC_OscInitStruct.PLL.PLLQ = 2;
  RCC_OscInitStruct.PLL.PLLR = 2;
  if (HAL_RCC_OscConfig(&RCC_OscInitStruct) != HAL_OK)
  {
    Error_Handler();
  }

  /** Initializes the CPU, AHB and APB buses clocks
  */
  RCC_ClkInitStruct.ClockType = RCC_CLOCKTYPE_HCLK|RCC_CLOCKTYPE_SYSCLK
                              |RCC_CLOCKTYPE_PCLK1|RCC_CLOCKTYPE_PCLK2;
  RCC_ClkInitStruct.SYSCLKSource = RCC_SYSCLKSOURCE_PLLCLK;
  RCC_ClkInitStruct.AHBCLKDivider = RCC_SYSCLK_DIV1;
  RCC_ClkInitStruct.APB1CLKDivider = RCC_HCLK_DIV2;
  RCC_ClkInitStruct.APB2CLKDivider = RCC_HCLK_DIV2;

  if (HAL_RCC_ClockConfig(&RCC_ClkInitStruct, FLASH_LATENCY_1) != HAL_OK)
  {
    Error_Handler();
  }
}

/**
  * @brief ADC1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_ADC1_Init(void)
{

  /* USER CODE BEGIN ADC1_Init 0 */

  /* USER CODE END ADC1_Init 0 */



  /* USER CODE BEGIN ADC1_Init 1 */

  /* USER CODE END ADC1_Init 1 */

  /** Configure the global features of the ADC (Clock, Resolution, Data Alignment and number of conversion)
  */
  hadc1.Instance = ADC1;
  hadc1.Init.ClockPrescaler = ADC_CLOCK_SYNC_PCLK_DIV2;
  hadc1.Init.Resolution = ADC_RESOLUTION_12B;
  hadc1.Init.ScanConvMode = ENABLE;
  hadc1.Init.ContinuousConvMode = DISABLE;
  hadc1.Init.DiscontinuousConvMode = DISABLE;
  hadc1.Init.ExternalTrigConvEdge = ADC_EXTERNALTRIGCONVEDGE_NONE;
  hadc1.Init.ExternalTrigConv = ADC_SOFTWARE_START;
  hadc1.Init.DataAlign = ADC_DATAALIGN_RIGHT;
  hadc1.Init.NbrOfConversion = 3;
  hadc1.Init.DMAContinuousRequests = DISABLE;
  hadc1.Init.EOCSelection = ADC_EOC_SINGLE_CONV;
  if (HAL_ADC_Init(&hadc1) != HAL_OK)
  {
    Error_Handler();
  }

  /** Configure for the selected ADC regular channel its corresponding rank in the sequencer and its sample time.

  /* USER CODE BEGIN ADC1_Init 2 */

  /* USER CODE END ADC1_Init 2 */

}

/**
  * @brief I2C1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_I2C1_Init(void)
{

  /* USER CODE BEGIN I2C1_Init 0 */

  /* USER CODE END I2C1_Init 0 */

  /* USER CODE BEGIN I2C1_Init 1 */

  /* USER CODE END I2C1_Init 1 */
  hi2c1.Instance = I2C1;
  hi2c1.Init.ClockSpeed = 100000;
  hi2c1.Init.DutyCycle = I2C_DUTYCYCLE_2;
  hi2c1.Init.OwnAddress1 = 0;
  hi2c1.Init.AddressingMode = I2C_ADDRESSINGMODE_7BIT;
  hi2c1.Init.DualAddressMode = I2C_DUALADDRESS_DISABLE;
  hi2c1.Init.OwnAddress2 = 0;
  hi2c1.Init.GeneralCallMode = I2C_GENERALCALL_DISABLE;
  hi2c1.Init.NoStretchMode = I2C_NOSTRETCH_DISABLE;
  if (HAL_I2C_Init(&hi2c1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN I2C1_Init 2 */

  /* USER CODE END I2C1_Init 2 */

}

/**
  * @brief RTC Initialization Function
  * @param None
  * @retval None
  */
static void MX_RTC_Init(void)
{

  /* USER CODE BEGIN RTC_Init 0 */

  /* USER CODE END RTC_Init 0 */


  /* USER CODE BEGIN RTC_Init 1 */

  /* USER CODE END RTC_Init 1 */

  /** Initialize RTC Only
  */
  hrtc.Instance = RTC;
  hrtc.Init.HourFormat = RTC_HOURFORMAT_24;
  hrtc.Init.AsynchPrediv = 127;
  hrtc.Init.SynchPrediv = 255;
  hrtc.Init.OutPut = RTC_OUTPUT_DISABLE;
  hrtc.Init.OutPutPolarity = RTC_OUTPUT_POLARITY_HIGH;
  hrtc.Init.OutPutType = RTC_OUTPUT_TYPE_OPENDRAIN;
  if (HAL_RTC_Init(&hrtc) != HAL_OK)
  {
    Error_Handler();
  }
  /* Set time/date only if RTC has never been initialized */
  if (HAL_RTCEx_BKUPRead(&hrtc, RTC_BKP_DR0) != RTC_BACKUP_MAGIC)
  {
      RTC_TimeTypeDef sTime = {0};
      RTC_DateTypeDef sDate = {0};

      /* Put the correct initial time here */
      sTime.Hours = 13;
      sTime.Minutes = 25;
      sTime.Seconds = 10;
      sTime.DayLightSaving = RTC_DAYLIGHTSAVING_NONE;
      sTime.StoreOperation = RTC_STOREOPERATION_RESET;

      if (HAL_RTC_SetTime(&hrtc, &sTime, RTC_FORMAT_BIN) != HAL_OK)
      {
          Error_Handler();
      }

      /* Put the correct initial date here */
      sDate.WeekDay = RTC_WEEKDAY_TUESDAY;
      sDate.Month = RTC_MONTH_AUGUST;
      sDate.Date = 19;
      sDate.Year = 26;  /* 2026 */

      if (HAL_RTC_SetDate(&hrtc, &sDate, RTC_FORMAT_BIN) != HAL_OK)
      {
          Error_Handler();
      }

      /* Marks the RTC as initialized */
      HAL_RTCEx_BKUPWrite(
          &hrtc,
          RTC_BKP_DR0,
          RTC_BACKUP_MAGIC
      );
  }
  /* USER CODE BEGIN Check_RTC_BKUP */

  /* USER CODE END Check_RTC_BKUP */

  /** Initialize RTC and set the Time and Date
  */

  /** Enable the WakeUp
  */
  if (HAL_RTCEx_SetWakeUpTimer_IT(&hrtc, 0, RTC_WAKEUPCLOCK_RTCCLK_DIV16) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN RTC_Init 2 */

  /* USER CODE END RTC_Init 2 */

}

/**
  * @brief USART1 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART1_UART_Init(void)
{

  /* USER CODE BEGIN USART1_Init 0 */

  /* USER CODE END USART1_Init 0 */

  /* USER CODE BEGIN USART1_Init 1 */

  /* USER CODE END USART1_Init 1 */
  huart1.Instance = USART1;
  huart1.Init.BaudRate = 115200;
  huart1.Init.WordLength = UART_WORDLENGTH_8B;
  huart1.Init.StopBits = UART_STOPBITS_1;
  huart1.Init.Parity = UART_PARITY_NONE;
  huart1.Init.Mode = UART_MODE_TX_RX;
  huart1.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart1.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_HalfDuplex_Init(&huart1) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART1_Init 2 */

  /* USER CODE END USART1_Init 2 */

}

/**
  * @brief USART2 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART2_UART_Init(void)
{

  /* USER CODE BEGIN USART2_Init 0 */

  /* USER CODE END USART2_Init 0 */

  /* USER CODE BEGIN USART2_Init 1 */

  /* USER CODE END USART2_Init 1 */
  huart2.Instance = USART2;
  huart2.Init.BaudRate = 115200;
  huart2.Init.WordLength = UART_WORDLENGTH_8B;
  huart2.Init.StopBits = UART_STOPBITS_1;
  huart2.Init.Parity = UART_PARITY_NONE;
  huart2.Init.Mode = UART_MODE_TX_RX;
  huart2.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart2.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart2) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART2_Init 2 */

  /* USER CODE END USART2_Init 2 */

}

/**
  * @brief USART3 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART3_UART_Init(void)
{

  /* USER CODE BEGIN USART3_Init 0 */

  /* USER CODE END USART3_Init 0 */

  /* USER CODE BEGIN USART3_Init 1 */

  /* USER CODE END USART3_Init 1 */
  huart3.Instance = USART3;
  huart3.Init.BaudRate = 9600;
  huart3.Init.WordLength = UART_WORDLENGTH_8B;
  huart3.Init.StopBits = UART_STOPBITS_1;
  huart3.Init.Parity = UART_PARITY_NONE;
  huart3.Init.Mode = UART_MODE_TX_RX;
  huart3.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart3.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart3) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART3_Init 2 */

  /* USER CODE END USART3_Init 2 */

}

/**
  * @brief USART6 Initialization Function
  * @param None
  * @retval None
  */
static void MX_USART6_UART_Init(void)
{

  /* USER CODE BEGIN USART6_Init 0 */

  /* USER CODE END USART6_Init 0 */

  /* USER CODE BEGIN USART6_Init 1 */

  /* USER CODE END USART6_Init 1 */
  huart6.Instance = USART6;
  huart6.Init.BaudRate = 9600;
  huart6.Init.WordLength = UART_WORDLENGTH_8B;
  huart6.Init.StopBits = UART_STOPBITS_1;
  huart6.Init.Parity = UART_PARITY_NONE;
  huart6.Init.Mode = UART_MODE_TX_RX;
  huart6.Init.HwFlowCtl = UART_HWCONTROL_NONE;
  huart6.Init.OverSampling = UART_OVERSAMPLING_16;
  if (HAL_UART_Init(&huart6) != HAL_OK)
  {
    Error_Handler();
  }
  /* USER CODE BEGIN USART6_Init 2 */

  /* USER CODE END USART6_Init 2 */

}

/**
  * Enable DMA controller clock
  */
static void MX_DMA_Init(void)
{

  /* DMA controller clock enable */
  __HAL_RCC_DMA2_CLK_ENABLE();

  /* DMA interrupt init */
  /* DMA2_Stream2_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA2_Stream2_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA2_Stream2_IRQn);
  /* DMA2_Stream7_IRQn interrupt configuration */
  HAL_NVIC_SetPriority(DMA2_Stream7_IRQn, 0, 0);
  HAL_NVIC_EnableIRQ(DMA2_Stream7_IRQn);

}

/**
  * @brief GPIO Initialization Function
  * @param None
  * @retval None
  */
static void MX_GPIO_Init(void)
{
  /* USER CODE BEGIN MX_GPIO_Init_1 */

  /* USER CODE END MX_GPIO_Init_1 */

  /* GPIO Ports Clock Enable */
  __HAL_RCC_GPIOC_CLK_ENABLE();
  __HAL_RCC_GPIOH_CLK_ENABLE();
  __HAL_RCC_GPIOA_CLK_ENABLE();
  __HAL_RCC_GPIOB_CLK_ENABLE();

  /* USER CODE BEGIN MX_GPIO_Init_2 */

  /* USER CODE END MX_GPIO_Init_2 */
}

/* USER CODE BEGIN 4 */

/* USER CODE END 4 */

/**
  * @brief  This function is executed in case of error occurrence.
  * @retval None
  */
void Error_Handler(void)
{
  /* USER CODE BEGIN Error_Handler_Debug */
  /* User can add his own implementation to report the HAL error return state */
  __disable_irq();
  while (1)
  {
  }
  /* USER CODE END Error_Handler_Debug */
}
#ifdef USE_FULL_ASSERT
/**
  * @brief  Reports the name of the source file and the source line number
  *         where the assert_param error has occurred.
  * @param  file: pointer to the source file name
  * @param  line: assert_param error line source number
  * @retval None
  */
void assert_failed(uint8_t *file, uint32_t line)
{
  /* USER CODE BEGIN 6 */
  /* User can add his own implementation to report the file name and line number,
     ex: printf("Wrong parameters value: file %s on line %d\r\n", file, line) */
  /* USER CODE END 6 */
}
#endif /* USE_FULL_ASSERT */
